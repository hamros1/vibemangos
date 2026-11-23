/**
 * Creature scripts: `creature_ai_scripts`' events and
 * actions for the creatures whose `AIName` is `EventAI`.
 *
 * Each event waits for its moment: timers in and out of combat (or both), health and mana between two
 * percentages (its own, or its victim's), the victim in a range, casting, behind or before it, or out of
 * reach, the fight starting, a kill (of a player, if it asks), death, evading, spawning (on a map or in a
 * zone, if it asks), reaching home, an aura of its own or its victim's there (with so many stacks) or
 * missing, a spell hitting it or one of its spells hitting another, a player's emote at it, a friend near it
 * hurt, held or missing a buff, an enemy at a range, someone coming into its sight out of combat, a
 * creature it summoned, or that one's death. Conditions (`conditions`) on deaths, emotes and sightings are
 * the killer's, emoter's or sighted player's. Then (by its chance, in the phases its mask allows) its
 * actions run: casting a spell (at itself, its victim, another on its threat list chosen as CMaNGOS chooses:
 * in the spell's range, players only if the cast says so; the one who caused the event or its owner, the
 * friend the event found, its summoner, the player who tapped it), saying, yelling or emoting a text
 * (`broadcast_text`, or one of a `dbscript_random_templates` group, or by a chance), an emote, a sound,
 * setting or stepping its phase, fleeing, calling for help, turning combat movement or its swings on or off,
 * keeping its distance to cast (ranged mode) or chasing at a distance and angle, standing up or down, unit
 * flags, taking an aura off, despawning, not dying of damage, its react state, its faction, a random phase,
 * quest events and kill credit, relay scripts, evading, attacking, its movement (standing, wandering, its
 * waypoints) and pausing its waypoints. Repeating events go again after their repeat timers.
 *
 * Also: summons, faction changes, morphs and mounts, the sheath, dying, a dungeon's players all
 * joining the fight (zone combat pulse), and setting instance data (a signal to the dungeon copy's
 * script, the field its id and the data its value).
 *
 * Also threat percentages, setting a unit field, walking or running, facing, and being held in place.
 *
 * And becoming another entry (updating the template).
 *
 * Every event, action and target type the database uses is done. Not yet: following, immunities, the cast
 * flags for casting targets and for switching caster and target. Spell lists (`creature_spell_list`) are run
 * by the creature AI itself.
 */
module dmangos.world.eventai;

import std.random : uniform;

import dmangos.mysql : MySqlConnection;

/// The event types (`event_type`), the ones handled.
enum EventType : ubyte
{
    timerInCombat = 0,
    timerOutOfCombat = 1,
    hp = 2,
    mana = 3,
    aggro = 4,
    kill = 5,
    death = 6,
    evade = 7,
    spellHit = 8,
    range = 9,
    spawned = 11,
    targetHp = 12,
    targetCasting = 13,
    friendlyHp = 14,
    reachedHome = 21,
    receiveEmote = 22,
    receiveAiEvent = 30,
    aura = 23,
    missingAura = 27,
    oocLineOfSight = 10,
    friendlyIsCrowdControlled = 15,
    friendlyMissingBuff = 16,
    summonedUnit = 17,
    targetMana = 18,
    targetAura = 24,
    summonedJustDied = 25,
    targetMissingAura = 28,
    timerGeneric = 29,
    selectAttackingTarget = 32,
    facingTarget = 33,
    spellHitTarget = 34,
    targetNotReachable = 36,
}

/// A `creature_ai_summons` row: where a summon stands, and for how long (seconds; 0: until out of combat).
struct SummonSpot
{
    import dmangos.world.movement : Position;

    Position position;
    uint seconds;
}

/// The action types (`action*_type`), the ones handled.
enum ActionType : ubyte
{
    none = 0,
    text = 1,
    setFaction = 2,
    sound = 4,
    emote = 5,
    randomEmote = 10,
    castSpell = 11,
    spawn = 12,
    questEvent = 15,
    setUnitFlag = 18,
    removeUnitFlag = 19,
    autoAttack = 20,
    combatMovement = 21,
    setPhase = 22,
    incPhase = 23,
    evade = 24,
    fleeForAssist = 25,
    questEventAll = 26,
    removeAurasFromSpell = 28,
    randomPhase = 30,
    randomPhaseRange = 31,
    summonId = 32,
    killedMonster = 33,
    callForHelp = 39,
    forceDespawn = 41,
    setDeathPrevention = 42,
    chancedText = 44,
    throwAiEvent = 45,
    setStandState = 47,
    setReactState = 50,
    startRelayScript = 53,
    textNew = 54,
    morph = 3,
    threatSinglePct = 13,
    threatAllPct = 14,
    setUnitField = 17,
    setWalk = 58,
    setFacing = 59,
    setImmobilized = 61,
    updateTemplate = 36,
    setInstanceData = 34,
    die = 37,
    zoneCombatPulse = 38,
    setSheath = 40,
    mount = 43,
    attackStart = 55,
    despawnGuardians = 56,
    setRangedMode = 57,
    rangedMovement = 29,
    changeMovement = 48,
    pauseWaypoints = 51,
}

/// `event_flags`
enum uint eventRepeatable = 0x01, eventRandomAction = 0x20, eventRangedModeOnly = 0x100, eventMeleeModeOnly = 0x200,
    eventCombatAction = 0x400;

/// The cast flags of the cast action.
enum uint castInterruptPrevious = 0x01, castTriggered = 0x02, castForceCast = 0x04, castNoMeleeIfOom = 0x08,
    castForceTargetSelf = 0x10, castAuraNotPresent = 0x20;

/// The targets of actions, the ones handled.
enum EventTarget : int
{
    self = 0,
    hostile = 1,
    hostileSecondAggro = 2,
    hostileLastAggro = 3,
    hostileRandom = 4,
    hostileRandomNotTop = 5,
    actionInvoker = 6,
    hostileRandomPlayer = 8,
    hostileRandomNotTopPlayer = 9,
    eventSender = 10,
    eventSpecific = 12,
    none = 15,
    actionInvokerOwner = 7,
    spawner = 11,
    playerInvoker = 13,
    playerTapped = 14,
    hostileRandomMana = 16,
    nearestAoeTarget = 17,
    hostileFarthestAway = 18,
}

/// One action of an event.
struct EventAiAction
{
    ubyte type;
    int[3] params;
}

/// A `creature_ai_scripts` row.
struct EventAiEvent
{
    uint id;
    uint creature;
    ubyte type;
    uint inversePhaseMask;
    uint chance;
    uint flags;
    int[6] params;
    EventAiAction[3] actions;
}

/// The scripts by creature entry, and the random text groups.
final class EventAiData
{
    EventAiEvent[][uint] byCreature;    /// by creature entry
    EventAiEvent[][uint] bySpawn;       /// by spawn guid (a negative `creature_id`)
    uint[][uint] textGroups;          /// `dbscript_random_templates` of type 0: id -> broadcast text ids
    SummonSpot[uint] summons;         /// `creature_ai_summons`

    /// Reads `creature_ai_scripts` and the text groups of `dbscript_random_templates`.
    static EventAiData load(MySqlConnection world)
    {
        import dmangos.log : info;

        auto data = new EventAiData;
        size_t count;
        foreach (row; world.query!eventAiQuery())
        {
            EventAiEvent e;
            e.id = row.get!uint(0);
            const key = row.get!long(1);
            e.type = cast(ubyte) row.get!uint(2);
            e.inversePhaseMask = cast(uint) row.get!long(3);
            e.chance = row.get!uint(4);
            e.flags = row.get!uint(5);
            foreach (i; 0 .. 6)
                e.params[i] = row.get!int(6 + i);
            foreach (a; 0 .. 3)
            {
                e.actions[a].type = cast(ubyte) row.get!uint(12 + a * 4);
                foreach (i; 0 .. 3)
                    e.actions[a].params[i] = row.get!int(13 + a * 4 + i);
            }
            if (key >= 0)
            {
                e.creature = cast(uint) key;
                data.byCreature[e.creature] ~= e;
            }
            else
                data.bySpawn[cast(uint) -key] ~= e;
            ++count;
        }
        foreach (row; world.query!"SELECT id, position_x, position_y, position_z, orientation, spawntimesecs FROM creature_ai_summons"())
            data.summons[row.get!uint(0)] = SummonSpot(SummonSpot.Position(row.get!float(1), row.get!float(2), row.get!float(3),
                row.get!float(4)), row.get!uint(5));
        foreach (row; world.query!"SELECT id, target_id FROM dbscript_random_templates WHERE type = 0"())
            data.textGroups[row.get!uint(0)] ~= cast(uint) row.get!int(1);
        info!"loaded %s creature scripts for %s creatures and %s spawns, %s random text groups"(count,
            data.byCreature.length, data.bySpawn.length, data.textGroups.length);
        return data;
    }

    /// The events of a creature: its entry's, then its spawn's.
    const(EventAiEvent)[] eventsOf(uint entry, uint spawnGuid) const
    {
        return byCreature.get(entry, null) ~ bySpawn.get(spawnGuid, null);
    }

    /// A text of group `id`, at random; 0 if it has none.
    uint randomText(uint id) const
    {
        const texts = textGroups.get(id, null);
        return texts.length ? texts[uniform(0, texts.length)] : 0;
    }
}

/// The `creature_ai_scripts` query, in `EventAiEvent` order.
enum eventAiQuery = "SELECT id, creature_id, event_type, event_inverse_phase_mask, event_chance, event_flags, "
    ~ "event_param1, event_param2, event_param3, event_param4, event_param5, event_param6, action1_type, "
    ~ "action1_param1, action1_param2, action1_param3, action2_type, action2_param1, action2_param2, action2_param3, "
    ~ "action3_type, action3_param1, action3_param2, action3_param3 FROM creature_ai_scripts";

/// An event as it stands for one creature.
struct EventHolder
{
    const(EventAiEvent)* event;
    uint timer;
    bool enabled = true;
    ulong eventTarget;   /// what the event found (a friend to heal)
    bool selectedChannelTarget; /// keep the wounded ally as the channel target
}

/**
 * What the creature's AI does for its script: the AI calls these at its moments, and the script
 * calls back for what the actions do (`Scripted`, implemented by `CreatureAI`).
 */
interface Scripted
{
    /// The creature's health and mana in percent; whether it is in combat.
    uint healthPercent();
    uint manaPercent(); /// ditto
    @property bool fighting(); /// ditto

    /// Whether it has an aura of `spell` on itself.
    bool hasOwnAura(uint spell);

    /// Whether its victim is casting.
    bool victimCasting();

    /// The friend within `radius` most hurt, by at least `deficit`
    /// (health, or percent); 0 if none.
    ulong lowestHpFriendly(float radius, uint deficit, bool percent, scope const(EventAiAction)[] actions,
        out bool selectedChannelTarget);

    /// Plays a sound around it.
    void scriptSound(uint sound);

    /// Unit flags set on or cleared from a target.
    void scriptUnitFlags(ulong target, uint flags, bool set);

    /// Its melee swings on or off.
    void scriptMelee(bool on);

    /// Takes the aura of `spell` off a target.
    void scriptRemoveAura(ulong target, uint spell);

    /// It despawns after `delay` milliseconds.
    void scriptDespawn(uint delay);

    /// It does not die of damage (left at 1 health).
    void scriptDeathPrevention(bool on);

    /// Its react state: 0 passive, 1 defensive, 2 aggressive.
    void scriptReactState(uint state);

    /// Starts relay script `id` (negative: one of group -`id`), at `target`.
    void scriptRelay(int id, ulong target);

    /// A temporary faction; 0 puts its own back.
    void scriptFaction(uint faction);

    /// Its look: model `model`, or (0) its own again; mounted on `model` (0: off its mount); sheath state.
    void scriptMorph(uint entry, uint model);
    void scriptMount(uint entry, uint model); /// ditto
    void scriptSheath(uint state); /// ditto

    /// It dies; a dungeon's players all join its fight; its dungeon copy's script is signalled.
    void scriptDie();
    void scriptZoneCombatPulse(); /// ditto
    void scriptInstanceData(uint field, int value); /// ditto

    /// Its threat of `target` (0: everyone on its threat list) changed by `percent` (-100: forgotten).
    void scriptThreatPercent(ulong target, int percent);
    /// A unit field of a creature `target` set (not the object's own fields).
    void scriptUnitField(ulong target, uint field, uint value);
    /// Walking or running: 0 walking, 1 running, 2 walking to chase, 3 running to chase.
    void scriptWalk(uint type);
    /// It turns to `target`, or (`reset`) back the way it faces at its spawn.
    void scriptFace(ulong target, bool reset);
    /// Held where it stands (`on`), until it leaves the fight if `combatOnly`.
    void scriptImmobilized(bool on, bool combatOnly);
    /// It becomes a creature of `entry` (its look, faction, flags and stats); false if it cannot.
    bool scriptUpdateTemplate(uint entry);

    /// A quest's event happens for the player `player`, or (`all`) every player fighting it.
    void scriptQuestEvent(uint quest, ulong player, bool all);

    /// Kill credit of `entry` for the player `player`.
    void scriptKillCredit(uint entry, ulong player);

    /// An AI event of `type` to the friendly creatures within `radius`, `invoker` its invoker.
    void scriptThrowAiEvent(uint type, float radius, ulong invoker);

    /// Summons a creature of `entry`: near it, or at summon spot `spot` (`creature_ai_summons`); it
    /// attacks `target` (0: none). False if it could not be summoned.
    bool scriptSummon(uint entry, ulong target, uint durationMs, uint spot);

    /// The victim's health in percent and distance in yards; uint.max if it has none.
    uint victimHealthPercent();
    float victimDistance(); /// ditto

    /// The target of an action by its type; 0 if there is none.
    ulong targetFor(int type, ulong invoker);

    /// Casts `spell` at `target` as `flags` say: false if it could not.
    bool scriptCast(uint spell, ulong target, uint flags, bool selectedChannelTarget = false);

    /// A broadcast text, said, yelled, emoted or whispered as the text says.
    void scriptText(uint text, ulong target);

    /// An emote; a stand state.
    void scriptEmote(uint emote);
    void scriptStandState(uint state); /// ditto

    /// Fleeing, calling for help, evading, attacking.
    bool scriptFlee();
    void scriptCallForHelp(float radius); /// ditto
    void scriptEvade(); /// ditto
    void scriptAttack(ulong target); /// ditto

    /// Combat movement on or off; ranged mode (keeping its distance to cast).
    void scriptCombatMovement(bool on);
    void scriptRangedMode(bool on, float distance); /// ditto
    @property bool rangedMode(); /// ditto

    /// The stacks of the aura of `spell` on it, or (`onVictim`) on its victim; 0 if there is none.
    uint auraStacks(bool onVictim, uint spell);

    /// Its victim's mana in percent; uint.max if it has no victim, or one without mana.
    uint victimManaPercent();

    /// A friend within `radius` (itself too), fighting and held: rooted, stunned, slowed, fleeing or
    /// confused; 0 if none.
    ulong crowdControlledFriend(float radius);

    /// A friend (itself too) within the range of `spell` without its aura: only those fighting (`inCombat`), or
    /// only those not; 0 if none.
    ulong friendMissingBuff(uint spell, bool inCombat);

    /// One on its threat list at random, between `min` and `max` yards (combat reach left out); 0 if none.
    ulong attackerWithin(float min, float max);

    /// Whether it stands within 5 yards in front of its victim (`front`), or behind it.
    bool besideVictim(bool front);

    /// Whether it chases a victim its way does not reach.
    bool victimUnreachable();

    /**
     * The targets picked from its threat list (CMaNGOS's `SelectAttackingTarget`): the second, the last, one at
     * random (not the first; a player; one with mana), the nearest within the radius of `spell`, the farthest
     * out of melee reach; only players with `CAST_PLAYER_ONLY` among `castFlags`, only those without the aura
     * with `CAST_AURA_NOT_PRESENT`, only those `spell` reaches unless it is cast triggered or forced. And the
     * invoker's owner, its summoner, the player who tapped it. 0 if there is none.
     */
    ulong moreTargetFor(int type, ulong invoker, uint spell, uint castFlags);

    /// It keeps `distance` yards from its victim, at `angle` degrees, when it chases.
    void scriptRangedMovement(float distance, float angle);

    /// Its movement: 0 standing, 1 wandering `param` yards, 2 its waypoints; its default from now if `asDefault`.
    void scriptChangeMovement(uint type, int param, bool asDefault);

    /// Its waypoints paused (it stands) or going on.
    void scriptPauseWaypoints(bool pause);

    /// Whether it spawned where `EVENT_T_SPAWNED` asks: anywhere (0), on map `value` (1), in zone or area
    /// `value` (2).
    bool spawnedIn(uint condition, uint value);

    /// Whether `who` (or the player controlling it) meets condition `id` (`conditions`).
    bool conditionMet(uint id, ulong who);
}

/// See the module documentation.
final class EventAI
{
    private EventHolder[] holders;
    private const EventAiData data;
    private uint phase;
    private ulong eventTarget; // the event's own target, for `TARGET_T_EVENT_SPECIFIC`
    private ulong eventSender; // the creature that sent an AI event, for `TARGET_T_EVENT_SENDER`
    private int updateIn = 500;     // the timers are looked at twice a second
    private uint pendingDiff;
    private bool spawnPending = true;
    private bool hasOutOfCombatTimers;

    ///
    this(const(EventAiEvent)[] events, const EventAiData data)
    {
        this.data = data;
        foreach (ref e; events)
        {
            holders ~= EventHolder(&e);
            switch (e.type)
            {
            case EventType.timerOutOfCombat, EventType.missingAura, EventType.aura, EventType.timerGeneric:
                hasOutOfCombatTimers = true;
                break;
            case EventType.friendlyMissingBuff:
                hasOutOfCombatTimers |= (e.params[4] & 3) != 0; // its flags: also, or only, out of combat
                break;
            case EventType.oocLineOfSight:
                hasLineOfSightEvents = true;
                break;
            default:
                break;
            }
        }
        resetSpawned();
    }

    private bool hasLineOfSightEvents;

    /// Whether it needs ticks out of combat: timers there, or its spawn events still to run.
    @property bool wantsTicks() const
    {
        return spawnPending || hasOutOfCombatTimers;
    }

    /// Whether it watches for those coming into its sight out of combat (`EVENT_T_OOC_LOS`).
    @property bool watchesLineOfSight() const
    {
        return hasLineOfSightEvents;
    }

    /// It has spawned: the timers start (in combat ones wait for the fight).
    private void resetSpawned()
    {
        foreach (ref h; holders)
        {
            h.enabled = true;
            h.timer = 0;
            if (h.event.type == EventType.timerOutOfCombat || h.event.type == EventType.timerInCombat
                    || h.event.type == EventType.timerGeneric)
                setTimer(h, h.event.params[0], h.event.params[1]);
        }
    }

    /// Sets the timer to between `min` and `max`; with `max` below `min` the event is off.
    private static void setTimer(ref EventHolder h, int min, int max)
    {
        if (min == max)
            h.timer = min > 0 ? min : 0;
        else if (max > min)
            h.timer = uniform!"[]"(min, max);
        else
            h.enabled = false;
    }

    /// The repeat timers of a timer-based event: most events' third and fourth parameters.
    private static void repeatTimers(const ref EventAiEvent e, out int min, out int max)
    {
        if (e.type == EventType.kill || e.type == EventType.targetCasting)
        {
            min = e.params[0];
            max = e.params[1];
        }
        else if (e.type == EventType.summonedUnit || e.type == EventType.summonedJustDied)
        {
            min = e.params[1];
            max = e.params[2];
        }
        else
        {
            min = e.params[2];
            max = e.params[3];
        }
    }

    /// Whether the event may go now.
    private bool check(ref EventHolder h, Scripted me)
    {
        const e = h.event;
        if (!h.enabled || h.timer)
            return false;
        if (e.inversePhaseMask & (1u << phase))
            return false;
        if (me.rangedMode ? (e.flags & eventMeleeModeOnly) : (e.flags & eventRangedModeOnly))
            return false;
        switch (e.type)
        {
        case EventType.timerInCombat:
            return me.fighting;
        case EventType.timerOutOfCombat:
            return !me.fighting;
        case EventType.hp:
        {
            if (!me.fighting)
                return false;
            const p = me.healthPercent;
            return p <= e.params[0] && p >= e.params[1];
        }
        case EventType.mana:
        {
            if (!me.fighting)
                return false;
            const p = me.manaPercent;
            return p <= e.params[0] && p >= e.params[1];
        }
        case EventType.targetHp:
        {
            if (!me.fighting)
                return false;
            const p = me.victimHealthPercent;
            return p != uint.max && p <= e.params[0] && p >= e.params[1];
        }
        case EventType.range:
        {
            if (!me.fighting)
                return false;
            const d = me.victimDistance;
            return d >= e.params[0] && d <= e.params[1];
        }
        case EventType.targetCasting:
            return me.fighting && me.victimCasting;
        case EventType.friendlyHp:
        {
            if (!me.fighting)
                return false;
            const friend = me.lowestHpFriendly(e.params[1], e.params[0], e.params[4] != 0, e.actions,
                h.selectedChannelTarget);
            h.eventTarget = friend;
            return friend != 0;
        }
        // An aura's stacks (at least one) there, or fewer than that.
        case EventType.aura:
            return me.auraStacks(false, e.params[0]) >= atLeastOne(e.params[1]);
        case EventType.missingAura:
            return me.auraStacks(false, e.params[0]) < atLeastOne(e.params[1]);
        case EventType.targetAura:
            return fightingSomeone(me) && me.auraStacks(true, e.params[0]) >= atLeastOne(e.params[1]);
        case EventType.targetMissingAura:
            return fightingSomeone(me) && me.auraStacks(true, e.params[0]) < atLeastOne(e.params[1]);
        case EventType.timerGeneric:
            return true;
        case EventType.spawned:
            return me.spawnedIn(e.params[0] > 0 ? e.params[0] : 0, e.params[1] > 0 ? e.params[1] : 0);
        case EventType.targetMana:
        {
            if (!me.fighting)
                return false;
            const p = me.victimManaPercent;
            return p != uint.max && p <= e.params[0] && p >= e.params[1];
        }
        case EventType.friendlyIsCrowdControlled:
        {
            // Its first parameter (a dispel type) is not looked at, as on CMaNGOS.
            if (!me.fighting)
                return false;
            h.eventTarget = me.crowdControlledFriend(e.params[1]);
            return h.eventTarget != 0;
        }
        case EventType.friendlyMissingBuff:
        {
            // Its flags: 0 only in combat, 1 in and out of it, 2 only out of it. The friends looked for are
            // those within the spell's range (its radius parameter is not used, as on CMaNGOS).
            const flags = e.params[4] & 3;
            if (flags == 0 && !me.fighting || flags == 2 && me.fighting)
                return false;
            h.eventTarget = me.friendMissingBuff(e.params[0], flags == 0 || flags == 1 && me.fighting);
            return h.eventTarget != 0;
        }
        case EventType.selectAttackingTarget:
            h.eventTarget = me.attackerWithin(e.params[0], e.params[1]);
            return h.eventTarget != 0;
        case EventType.facingTarget:
            // 0: behind its victim, 1: in front of it (within 5 yards).
            return fightingSomeone(me) && me.besideVictim(e.params[0] == 1);
        case EventType.targetNotReachable:
            return me.targetFor(EventTarget.hostile, 0) && me.victimUnreachable;
        default:
            return true;
        }
    }

    /// In combat, with a victim.
    private static bool fightingSomeone(Scripted me)
    {
        return me.fighting && me.targetFor(EventTarget.hostile, 0) != 0;
    }

    /// A stack count asked for: at least one.
    private static uint atLeastOne(int amount) pure nothrow @nogc @safe
    {
        return amount > 1 ? amount : 1;
    }

    /// By its chance, its actions (one at random with `EFLAG_RANDOM_ACTION`), then its reset.
    private void process(ref EventHolder h, Scripted me, ulong invoker)
    {
        eventTarget = h.eventTarget;
        const e = h.event;
        if (uniform(0, 100) >= e.chance)
            return reset(h);
        bool success;
        if (e.flags & eventRandomAction)
        {
            uint[] actions;
            foreach (i, ref a; e.actions)
                if (a.type != ActionType.none)
                    actions ~= cast(uint) i;
            if (actions.length)
                success = act(e.actions[actions[uniform(0, actions.length)]], me, invoker, h.selectedChannelTarget);
        }
        else
        {
            success = act(e.actions[0], me, invoker, h.selectedChannelTarget);
            if (!(e.flags & eventCombatAction) || success)
                foreach (ref a; e.actions[1 .. $])
                    act(a, me, invoker, h.selectedChannelTarget);
        }
        if (!(e.flags & eventCombatAction) || success)
            reset(h);
    }

    /// Timer-based events wait their repeat time; those that do not repeat are done.
    private void reset(ref EventHolder h)
    {
        const e = h.event;
        switch (e.type)
        {
        case EventType.spawned, EventType.death, EventType.aggro, EventType.evade, EventType.reachedHome:
            h.enabled = false; // these never happen again
            return;
        default:
            break;
        }
        int min, max;
        repeatTimers(*e, min, max);
        switch (e.type)
        {
        case EventType.timerInCombat, EventType.timerOutOfCombat, EventType.hp, EventType.mana, EventType.kill,
                EventType.range, EventType.targetHp, EventType.aura, EventType.missingAura, EventType.spellHit,
                EventType.targetCasting, EventType.friendlyHp, EventType.timerGeneric, EventType.oocLineOfSight,
                EventType.friendlyIsCrowdControlled, EventType.friendlyMissingBuff, EventType.summonedUnit,
                EventType.summonedJustDied, EventType.targetMana, EventType.targetAura, EventType.targetMissingAura,
                EventType.selectAttackingTarget, EventType.facingTarget, EventType.spellHitTarget:
            setTimer(h, min, max);
            break;
        default:
            break;
        }
        if (!(e.flags & eventRepeatable))
            h.enabled = false;
    }

    /// Runs one action; whether it succeeded.
    private bool act(const ref EventAiAction a, Scripted me, ulong invoker, bool selectedChannelTarget)
    {
        switch (a.type)
        {
        case ActionType.text:
        {
            // One of up to three texts.
            int text = a.params[0];
            const r = uniform(0, 6);
            if (a.params[1] && a.params[2])
                text = a.params[r % 3];
            else if (a.params[1] && (r % 2))
                text = a.params[1];
            if (text > 0)
                me.scriptText(text, invoker ? invoker : me.targetFor(EventTarget.hostile, invoker));
            return text > 0;
        }
        case ActionType.textNew:
        {
            // A text, or one of a group (its third parameter).
            const text = a.params[2] ? data.randomText(a.params[2]) : a.params[0];
            if (text)
                me.scriptText(text, me.targetFor(a.params[1], invoker));
            return text != 0;
        }
        case ActionType.emote:
            me.scriptEmote(a.params[0]);
            return true;
        case ActionType.chancedText:
        {
            // By its chance, one of up to two texts.
            if (uniform(0, 100) >= a.params[0] || a.params[1] <= 0)
                return false;
            const text = a.params[2] > 0 && uniform(0, 2) ? a.params[2] : a.params[1];
            me.scriptText(text, invoker ? invoker : me.targetFor(EventTarget.hostile, invoker));
            return true;
        }
        case ActionType.sound:
            me.scriptSound(a.params[0]);
            return true;
        case ActionType.setUnitFlag, ActionType.removeUnitFlag:
        {
            const target = targetOf(a.params[1], me, invoker);
            if (target)
                me.scriptUnitFlags(target, a.params[0], a.type == ActionType.setUnitFlag);
            return target != 0;
        }
        case ActionType.autoAttack:
            me.scriptMelee(a.params[0] != 0);
            return true;
        case ActionType.removeAurasFromSpell:
        {
            const target = targetOf(a.params[0], me, invoker);
            if (target)
                me.scriptRemoveAura(target, a.params[1]);
            return target != 0;
        }
        case ActionType.forceDespawn:
            me.scriptDespawn(a.params[0] > 0 ? a.params[0] : 0);
            return true;
        case ActionType.setDeathPrevention:
            me.scriptDeathPrevention(a.params[0] != 0);
            return true;
        case ActionType.setReactState:
            me.scriptReactState(a.params[0]);
            return true;
        case ActionType.setFaction:
            me.scriptFaction(a.params[0] > 0 ? a.params[0] : 0);
            return true;
        case ActionType.morph: // an entry's model or a model; neither: its own again
            me.scriptMorph(a.params[0] > 0 ? a.params[0] : 0, a.params[1] > 0 ? a.params[1] : 0);
            return true;
        case ActionType.mount: // an entry's model or a model; neither: off its mount
            me.scriptMount(a.params[0] > 0 ? a.params[0] : 0, a.params[1] > 0 ? a.params[1] : 0);
            return true;
        case ActionType.setSheath:
            me.scriptSheath(a.params[0] > 0 ? a.params[0] : 0);
            return true;
        case ActionType.die:
            me.scriptDie();
            return true;
        case ActionType.zoneCombatPulse:
            me.scriptZoneCombatPulse();
            return true;
        case ActionType.setInstanceData:
            me.scriptInstanceData(a.params[0] > 0 ? a.params[0] : 0, a.params[1]);
            return true;
        case ActionType.threatSinglePct:
        {
            const target = targetOf(a.params[1], me, invoker);
            if (target)
                me.scriptThreatPercent(target, a.params[0]);
            return target != 0;
        }
        case ActionType.threatAllPct:
            me.scriptThreatPercent(0, a.params[0]);
            return true;
        case ActionType.setUnitField:
        {
            const target = targetOf(a.params[2], me, invoker);
            if (target && a.params[0] > 0)
                me.scriptUnitField(target, a.params[0], cast(uint) a.params[1]);
            return target != 0;
        }
        case ActionType.setWalk:
            me.scriptWalk(a.params[0] > 0 ? a.params[0] : 0);
            return true;
        case ActionType.setFacing:
        {
            const target = a.params[1] ? 0 : targetOf(a.params[0], me, invoker);
            me.scriptFace(target, a.params[1] != 0);
            return true;
        }
        case ActionType.setImmobilized:
            me.scriptImmobilized(a.params[0] != 0, a.params[1] != 0);
            return true;
        case ActionType.updateTemplate:
            return a.params[0] > 0 && me.scriptUpdateTemplate(a.params[0]);
        case ActionType.startRelayScript:
            me.scriptRelay(a.params[0], targetOf(a.params[1], me, invoker));
            return a.params[0] != 0;
        case ActionType.questEvent:
        {
            const target = targetOf(a.params[1], me, invoker);
            if (target)
                me.scriptQuestEvent(a.params[0], target, false);
            return target != 0;
        }
        case ActionType.questEventAll:
            me.scriptQuestEvent(a.params[0], invoker, true);
            return true;
        case ActionType.killedMonster:
        {
            const target = targetOf(a.params[1], me, invoker);
            if (target)
                me.scriptKillCredit(a.params[0], target);
            return target != 0;
        }
        case ActionType.randomPhase:
        {
            // One of three phases (-1: none).
            int[] phases;
            foreach (p; a.params)
                if (p >= 0 && p <= 31)
                    phases ~= p;
            if (phases.length)
                phase = phases[uniform(0, phases.length)];
            return phases.length > 0;
        }
        case ActionType.randomPhaseRange:
            if (a.params[1] < a.params[0] || a.params[1] > 31 || a.params[0] < 0)
                return false;
            phase = uniform!"[]"(a.params[0], a.params[1]);
            return true;
        case ActionType.spawn, ActionType.summonId:
        {
            // ACTION_T_SPAWN (CreatureId, Target, Duration) or ACTION_T_SUMMON_ID (CreatureId, Target, SpawnId).
            const target = a.params[1] == EventTarget.self ? 0 : targetOf(a.params[1], me, invoker);
            return a.type == ActionType.spawn ? me.scriptSummon(a.params[0], target, a.params[2], 0)
                : me.scriptSummon(a.params[0], target, 0, a.params[2]);
        }
        case ActionType.throwAiEvent:
            me.scriptThrowAiEvent(a.params[0], a.params[1], targetOf(a.params[2], me, invoker));
            return true;
        case ActionType.despawnGuardians:
            return true; // creatures have no guardians here yet
        case ActionType.randomEmote:
        {
            int[] emotes;
            foreach (p; a.params)
                if (p > 0)
                    emotes ~= p;
            if (emotes.length)
                me.scriptEmote(emotes[uniform(0, emotes.length)]);
            return emotes.length > 0;
        }
        case ActionType.castSpell:
        {
            auto target = targetOf(a.params[1], me, invoker, a.params[0], a.params[2]);
            if (target == 0 && a.params[1] != EventTarget.none)
                return false;
            if (a.params[1] == EventTarget.nearestAoeTarget)
                target = 0; // only that there is one in reach: the spell finds its own
            return me.scriptCast(a.params[0], target, cast(uint) a.params[2], selectedChannelTarget);
        }
        case ActionType.rangedMovement:
            me.scriptRangedMovement(a.params[0], a.params[1]);
            return true;
        case ActionType.changeMovement:
            // Its type, the wander distance (or path), and its flags (1: from now its default).
            me.scriptChangeMovement(a.params[0] > 0 ? a.params[0] : 0, a.params[1], (a.params[2] & 1) != 0);
            return true;
        case ActionType.pauseWaypoints:
            me.scriptPauseWaypoints(a.params[0] != 0);
            return true;
        case ActionType.combatMovement:
            me.scriptCombatMovement(a.params[0] != 0);
            return true;
        case ActionType.setPhase:
            phase = a.params[0] < 0 ? 0 : a.params[0] > 31 ? 31 : a.params[0];
            return true;
        case ActionType.incPhase:
        {
            const next = cast(int) phase + a.params[0];
            phase = next < 0 ? 0 : next > 31 ? 31 : next;
            return true;
        }
        case ActionType.evade:
            me.scriptEvade();
            return true;
        case ActionType.fleeForAssist:
            return me.scriptFlee();
        case ActionType.callForHelp:
            me.scriptCallForHelp(a.params[0]);
            return true;
        case ActionType.setStandState:
            me.scriptStandState(a.params[0]);
            return true;
        case ActionType.attackStart:
        {
            const target = targetOf(a.params[0], me, invoker);
            if (target)
                me.scriptAttack(target);
            return target != 0;
        }
        case ActionType.setRangedMode:
            me.scriptRangedMode(a.params[0] != 0, a.params[1] > 0 ? a.params[1] : 20);
            return true;
        default: // none, and those not done yet
            return false;
        }
    }

    /// The target of an action by its type, with the event's own target (`TARGET_T_EVENT_SPECIFIC`).
    private ulong targetOf(int type, Scripted me, ulong invoker, uint spell = 0, uint castFlags = 0)
    {
        switch (type)
        {
        case EventTarget.eventSender:
            return eventSender;
        case EventTarget.eventSpecific:
            return eventTarget;
        case EventTarget.actionInvokerOwner, EventTarget.spawner, EventTarget.playerInvoker, EventTarget.playerTapped,
                EventTarget.hostileRandomMana, EventTarget.nearestAoeTarget, EventTarget.hostileFarthestAway,
                EventTarget.hostileSecondAggro, EventTarget.hostileLastAggro, EventTarget.hostileRandom,
                EventTarget.hostileRandomNotTop, EventTarget.hostileRandomPlayer, EventTarget.hostileRandomNotTopPlayer:
            return me.moreTargetFor(type, invoker, spell, castFlags);
        default:
            return me.targetFor(type, invoker);
        }
    }

    /// A spell (`spell` of `schoolMask`) hit it.
    void spellHit(Scripted me, ulong caster, uint spell, uint schoolMask)
    {
        foreach (ref h; holders)
            if (h.event.type == EventType.spellHit && check(h, me))
            {
                const e = h.event;
                // A spell named, or any of the schools in the mask (-1: any).
                if (e.params[0] ? e.params[0] != spell : !(schoolMask & cast(uint) e.params[1]))
                    continue;
                process(h, me, caster);
            }
    }

    /// Another creature's AI event of `type` (from `sender`, of `senderEntry`), `invoker` its cause.
    void aiEventReceived(Scripted me, uint type, ulong sender, uint senderEntry, ulong invoker)
    {
        foreach (ref h; holders)
            if (h.event.type == EventType.receiveAiEvent && h.event.params[0] == type
                && (h.event.params[1] == 0 || h.event.params[1] == senderEntry) && check(h, me))
            {
                eventSender = sender;
                process(h, me, invoker);
                eventSender = 0;
            }
    }

    /// Its spell hit `target` (`EVENT_T_SPELLHIT_TARGET`).
    void spellHitTarget(Scripted me, ulong target, uint spell, uint schoolMask)
    {
        foreach (ref h; holders)
            if (h.event.type == EventType.spellHitTarget && check(h, me))
            {
                const e = h.event;
                if (e.params[0] ? e.params[0] != spell : !(schoolMask & cast(uint) e.params[1]))
                    continue;
                process(h, me, target);
            }
    }

    /**
     * `who` came into its sight, `distance` yards away (`EVENT_T_OOC_LOS`): its events for those near enough, a
     * player if they ask for one, hostile to it (`enemy`) or not as they ask. The caller looks at the line of sight,
     * and only while it has no victim.
     */
    void seen(Scripted me, ulong who, bool enemy, bool player, float distance)
    {
        foreach (ref h; holders)
        {
            const e = h.event;
            if (e.type != EventType.oocLineOfSight || distance > e.params[1] || (e.params[4] && !player))
                continue;
            // Its first parameter: 1, those not hostile to it; 0, those hostile.
            if ((e.params[0] != 0) == enemy)
                continue;
            if (e.params[5] > 0 && player && !me.conditionMet(e.params[5], who)) // its condition, for a player
                continue;
            if (check(h, me))
                process(h, me, who);
        }
    }

    /// It summoned `summoned`, a creature of `entry` (`EVENT_T_SUMMONED_UNIT`).
    void summoned(Scripted me, ulong summoned, uint entry)
    {
        summonEvent(EventType.summonedUnit, me, summoned, entry);
    }

    /// A creature of `entry` it summoned died (`EVENT_T_SUMMONED_JUST_DIED`).
    void summonedDied(Scripted me, ulong summoned, uint entry)
    {
        summonEvent(EventType.summonedJustDied, me, summoned, entry);
    }

    private void summonEvent(EventType type, Scripted me, ulong summoned, uint entry)
    {
        foreach (ref h; holders)
            if (h.event.type == type && h.event.params[0] == entry && check(h, me))
                process(h, me, summoned);
    }

    /// A player's text emote at it.
    void receivedEmote(Scripted me, ulong player, uint emote)
    {
        foreach (ref h; holders)
            if (h.event.type == EventType.receiveEmote && h.event.params[0] == emote
                    && (h.event.params[1] <= 0 || me.conditionMet(h.event.params[1], player)) && check(h, me))
                process(h, me, player);
    }

    /// Runs the events of `type` that may go now.
    private void fire(EventType type, Scripted me, ulong invoker)
    {
        foreach (ref h; holders)
            if (h.event.type == type && check(h, me))
                process(h, me, invoker);
    }

    // -------------------------------------------------------------------
    // The AI's moments
    // -------------------------------------------------------------------

    /// The fight starts: the in-combat timers start, and the aggro events go.
    void combatStarted(Scripted me, ulong enemy)
    {
        foreach (ref h; holders)
            if (h.event.type == EventType.timerInCombat)
            {
                h.enabled = true;
                setTimer(h, h.event.params[0], h.event.params[1]);
            }
            else if (h.event.type == EventType.aggro)
                h.enabled = true;
            else if (h.event.type == EventType.friendlyHp || h.event.type == EventType.friendlyIsCrowdControlled
                    || h.event.type == EventType.friendlyMissingBuff || h.event.type == EventType.selectAttackingTarget)
            {
                // These wait their repeat time from the start of the fight.
                h.enabled = true;
                setTimer(h, h.event.params[2], h.event.params[3]);
            }
        fire(EventType.aggro, me, enemy);
        updateIn = 500;
        pendingDiff = 0;
    }

    /// It killed `victim`: its kill events (those with a third parameter of 1 for players only).
    void killed(Scripted me, ulong victim)
    {
        import dmangos.world.objects : HighGuid, highGuidOf;

        const player = highGuidOf(victim) == HighGuid.player;
        foreach (ref h; holders)
            if (h.event.type == EventType.kill && (h.event.params[2] != 1 || player) && check(h, me))
                process(h, me, victim);
    }

    /// It died: its death events (those with a condition, if its killer meets it).
    void died(Scripted me, ulong killer)
    {
        foreach (ref h; holders)
            if (h.event.type == EventType.death && (h.event.params[0] <= 0 || (killer && me.conditionMet(h.event.params[0],
                    killer))) && check(h, me))
                process(h, me, killer);
    }

    /// It evades: the evade events, then the events start over for out of combat.
    void evaded(Scripted me)
    {
        fire(EventType.evade, me, 0);
        phase = 0;
        foreach (ref h; holders)
            switch (h.event.type)
            {
            case EventType.timerInCombat, EventType.aggro, EventType.timerGeneric:
                break;
            case EventType.timerOutOfCombat:
                h.enabled = true;
                setTimer(h, h.event.params[0], h.event.params[1]);
                break;
            default:
                h.enabled = true;
                h.timer = 0;
                break;
            }
    }

    /// It is back at its spawn point.
    void reachedHome(Scripted me)
    {
        fire(EventType.reachedHome, me, 0);
    }

    /// The event timers, twice a second; the spawned events at the first.
    void update(Scripted me, int diff)
    {
        if (spawnPending)
        {
            spawnPending = false;
            fire(EventType.spawned, me, 0);
        }
        pendingDiff += diff;
        updateIn -= diff;
        if (updateIn > 0)
            return;
        updateIn = 500;
        foreach (ref h; holders)
        {
            if (h.timer && !(h.event.inversePhaseMask & (1u << phase)))
                h.timer = h.timer > pendingDiff ? h.timer - pendingDiff : 0;
            if (!h.enabled || h.timer)
                continue;
            switch (h.event.type)
            {
            case EventType.timerInCombat, EventType.timerOutOfCombat, EventType.hp, EventType.mana,
                    EventType.targetHp, EventType.range, EventType.aura, EventType.missingAura,
                    EventType.targetCasting, EventType.friendlyHp, EventType.timerGeneric,
                    EventType.friendlyIsCrowdControlled, EventType.friendlyMissingBuff, EventType.targetMana,
                    EventType.targetAura, EventType.targetMissingAura, EventType.selectAttackingTarget,
                    EventType.facingTarget, EventType.targetNotReachable:
                if (check(h, me))
                    process(h, me, 0);
                break;
            default:
                break;
            }
        }
        pendingDiff = 0;
    }
}

unittest
{
    // A creature that yells on aggro, casts every 5 to 6 seconds, and flees at 15% health.
    static final class Dummy : Scripted
    {
        uint health = 100;
        bool inFight;
        uint[] cast_, texts;
        bool fled;
        uint healthPercent() { return health; }
        uint manaPercent() { return 100; }
        @property bool fighting() { return inFight; }
        bool hasOwnAura(uint spell) { return false; }
        bool victimCasting() { return false; }
        ulong lowestHpFriendly(float radius, uint deficit, bool percent, scope const(EventAiAction)[] actions,
            out bool selectedChannelTarget) { return 0; }
        void scriptSound(uint sound) {}
        void scriptUnitFlags(ulong target, uint flags, bool set) {}
        void scriptMelee(bool on) {}
        void scriptRemoveAura(ulong target, uint spell) {}
        void scriptDespawn(uint delay) {}
        void scriptDeathPrevention(bool on) {}
        void scriptReactState(uint state) {}
        void scriptRelay(int id, ulong target) {}
        void scriptFaction(uint faction) {}
        void scriptMorph(uint entry, uint model) {}
        void scriptMount(uint entry, uint model) {}
        void scriptSheath(uint state) {}
        void scriptDie() {}
        void scriptZoneCombatPulse() {}
        void scriptInstanceData(uint field, int value) {}
        void scriptThreatPercent(ulong target, int percent) {}
        void scriptUnitField(ulong target, uint field, uint value) {}
        void scriptWalk(uint type) {}
        void scriptFace(ulong target, bool reset) {}
        void scriptImmobilized(bool on, bool combatOnly) {}
        bool scriptUpdateTemplate(uint entry) { return false; }
        void scriptQuestEvent(uint quest, ulong player, bool all) {}
        void scriptKillCredit(uint entry, ulong player) {}
        bool scriptSummon(uint entry, ulong target, uint durationMs, uint spot) { return false; }
        void scriptThrowAiEvent(uint type, float radius, ulong invoker) {}
        uint victimHealthPercent() { return 100; }
        float victimDistance() { return 2; }
        ulong targetFor(int type, ulong invoker) { return type == EventTarget.self ? 1 : 2; }
        bool scriptCast(uint spell, ulong target, uint flags, bool selectedChannelTarget)
        {
            cast_ ~= spell;
            castAt ~= target;
            return true;
        }
        void scriptText(uint text, ulong target) { texts ~= text; }
        void scriptEmote(uint emote) {}
        void scriptStandState(uint state) {}
        bool scriptFlee() { fled = true; return true; }
        void scriptCallForHelp(float radius) {}
        void scriptEvade() {}
        void scriptAttack(ulong target) {}
        void scriptCombatMovement(bool on) {}
        void scriptRangedMode(bool on, float distance) {}
        @property bool rangedMode() { return false; }
        uint[uint] victimAuras, ownAuras;
        uint victimMana = uint.max;
        ulong heldFriend, unbuffedFriend;
        bool behind, unreachable;
        ulong[] castAt;
        uint auraStacks(bool onVictim, uint spell) { return (onVictim ? victimAuras : ownAuras).get(spell, 0); }
        uint victimManaPercent() { return victimMana; }
        ulong crowdControlledFriend(float radius) { return heldFriend; }
        ulong friendMissingBuff(uint spell, bool inCombat) { return unbuffedFriend; }
        ulong attackerWithin(float min, float max) { return 0; }
        bool besideVictim(bool front) { return front != behind; }
        bool victimUnreachable() { return unreachable; }
        ulong moreTargetFor(int type, ulong invoker, uint spell, uint castFlags) { return 2; }
        void scriptRangedMovement(float distance, float angle) {}
        void scriptChangeMovement(uint type, int param, bool asDefault) {}
        void scriptPauseWaypoints(bool pause) {}
        bool spawnedIn(uint condition, uint value) { return condition == 0 || value == 1; }
        bool conditionMet(uint id, ulong who) { return id == 1; }
    }

    auto data = new EventAiData;
    EventAiEvent aggro = {id: 1, type: EventType.aggro, chance: 100};
    aggro.actions[0] = EventAiAction(ActionType.text, [100, 0, 0]);
    EventAiEvent bolt = {id: 2, type: EventType.timerInCombat, chance: 100, flags: eventRepeatable,
        params: [1000, 1000, 5000, 6000, 0, 0]};
    bolt.actions[0] = EventAiAction(ActionType.castSpell, [133, EventTarget.hostile, 0]);
    EventAiEvent flee = {id: 3, type: EventType.hp, chance: 100, params: [15, 0, 0, 0, 0, 0]};
    flee.actions[0] = EventAiAction(ActionType.fleeForAssist, [0, 0, 0]);
    const events = [aggro, bolt, flee];
    auto me = new Dummy;
    auto ai = new EventAI(events, data);
    ai.update(me, 500);
    assert(me.cast_.length == 0, "out of combat nothing happens");
    me.inFight = true;
    ai.combatStarted(me, 2);
    assert(me.texts == [100], "the aggro yell");
    ai.update(me, 500);
    ai.update(me, 500);
    assert(me.cast_ == [133], "the bolt after a second");
    foreach (_; 0 .. 8)
        ai.update(me, 500);
    assert(me.cast_.length == 1, "not again before five seconds");
    foreach (_; 0 .. 6)
        ai.update(me, 500);
    assert(me.cast_.length == 2, "again after five to six");
    me.health = 12;
    ai.update(me, 500);
    assert(me.fled, "flees at 15%");

    // The events of the rows it did not know before.
    {
        // A sunder at five stacks on its victim; a heal on a friend held; a strike from behind; a shout when it
        // cannot reach its victim; a nova at whoever is near (the spell picks); a drain on a victim low on mana.
        EventAiEvent sunder = {id: 10, type: EventType.targetAura, chance: 100, flags: eventRepeatable,
            params: [7386, 5, 1000, 1000, 0, 0]};
        sunder.actions[0] = EventAiAction(ActionType.castSpell, [1, EventTarget.hostile, 0]);
        EventAiEvent freedom = {id: 11, type: EventType.friendlyIsCrowdControlled, chance: 100, flags: eventRepeatable,
            params: [0, 30, 0, 0, 0, 0]};
        freedom.actions[0] = EventAiAction(ActionType.castSpell, [2, EventTarget.eventSpecific, 0]);
        EventAiEvent backstab = {id: 12, type: EventType.facingTarget, chance: 100, flags: eventRepeatable,
            params: [0, 0, 3000, 3000, 0, 0]};
        backstab.actions[0] = EventAiAction(ActionType.castSpell, [3, EventTarget.hostile, 0]);
        EventAiEvent stuck = {id: 13, type: EventType.targetNotReachable, chance: 100};
        stuck.actions[0] = EventAiAction(ActionType.text, [200, 0, 0]);
        EventAiEvent nova = {id: 14, type: EventType.timerGeneric, chance: 100, params: [0, 0, 0, 0, 0, 0]};
        nova.actions[0] = EventAiAction(ActionType.castSpell, [4, EventTarget.nearestAoeTarget, 0]);
        EventAiEvent drain = {id: 15, type: EventType.targetMana, chance: 100, params: [50, 0, 0, 0, 0, 0]};
        drain.actions[0] = EventAiAction(ActionType.castSpell, [5, EventTarget.hostile, 0]);
        const rows = [sunder, freedom, backstab, stuck, nova, drain];
        auto it = new Dummy;
        auto eai = new EventAI(rows, data);
        eai.update(it, 500);
        assert(it.cast_ == [4] && it.castAt == [0], "a generic timer goes out of combat too; the nova finds its own");
        it.inFight = true;
        eai.combatStarted(it, 2);
        it.victimAuras[7386] = 4;
        eai.update(it, 500);
        assert(it.cast_ == [4], "four stacks, in front, no friend held, a victim without mana: nothing");
        it.victimAuras[7386] = 5;
        it.heldFriend = 77;
        it.behind = true;
        it.victimMana = 40;
        eai.update(it, 500);
        assert(it.cast_ == [4, 1, 2, 3, 5], "the sunder, the friend's heal, the backstab and the drain");
        assert(it.castAt[2] == 77, "the heal at the friend the event found");
        it.unreachable = true;
        eai.update(it, 500);
        assert(it.texts == [200], "it cannot reach its victim");
        eai.update(it, 500);
        assert(it.texts == [200], "once (not repeatable)");
    }
    // In its sight out of combat: a greeting for players not hostile to it within 10 yards.
    {
        EventAiEvent greet = {id: 20, type: EventType.oocLineOfSight, chance: 100, flags: eventRepeatable,
            params: [1, 10, 5000, 5000, 1, 0]};
        greet.actions[0] = EventAiAction(ActionType.text, [300, 0, 0]);
        const rows = [greet];
        auto it = new Dummy;
        auto eai = new EventAI(rows, data);
        assert(eai.watchesLineOfSight);
        eai.seen(it, 5, true, true, 5);
        eai.seen(it, 5, false, false, 5);
        eai.seen(it, 5, false, true, 12);
        assert(it.texts.length == 0, "an enemy, a creature, one too far: no greeting");
        eai.seen(it, 5, false, true, 8);
        assert(it.texts == [300], "a friendly player near");
        eai.seen(it, 5, false, true, 8);
        assert(it.texts == [300], "not again before its repeat time");
    }

    // Conditions and players only: an emote answered only for those who meet its condition, a kill event
    // for players only.
    {
        EventAiEvent wave = {id: 30, type: EventType.receiveEmote, chance: 100, flags: eventRepeatable,
            params: [101, 2, 0, 0, 0, 0]};
        wave.actions[0] = EventAiAction(ActionType.text, [400, 0, 0]);
        EventAiEvent gloat = {id: 31, type: EventType.kill, chance: 100, flags: eventRepeatable,
            params: [0, 0, 1, 0, 0, 0]};
        gloat.actions[0] = EventAiAction(ActionType.text, [500, 0, 0]);
        const rows = [wave, gloat];
        auto it = new Dummy;
        auto eai = new EventAI(rows, data);
        eai.receivedEmote(it, 5, 101);
        assert(it.texts.length == 0, "condition 2 not met (the dummy meets only 1)");
        it.inFight = true;
        eai.killed(it, imported!"dmangos.world.objects".makeGuid(imported!"dmangos.world.objects".HighGuid.unit, 6, 7));
        assert(it.texts.length == 0, "a creature killed: not for it");
        eai.killed(it, 9);
        assert(it.texts == [500], "a player killed");
    }
}
