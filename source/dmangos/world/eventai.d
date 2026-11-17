/**
 * Creature scripts (CMaNGOS `AI/EventAI/CreatureEventAI.cpp`): `creature_ai_scripts`' events and
 * actions for the creatures whose `AIName` is `EventAI`.
 *
 * Each event waits for its moment: timers in and out of combat, health and mana between two
 * percentages, the victim in a range, the fight starting, a kill, death, evading, spawning,
 * reaching home, an aura of its own there or missing. Then (by its chance, in the phases its mask
 * allows) its actions run: casting a spell (at itself, its victim, another on its threat list, the
 * one who caused the event), saying, yelling or emoting a text (`broadcast_text`, or one of a
 * `dbscript_random_templates` group), an emote, setting or stepping its phase, fleeing, calling
 * for help, turning combat movement on or off, keeping its distance to cast (ranged mode),
 * standing up or down, evading, attacking. Repeating events go again after their repeat timers.
 *
 * Not yet: the other events and actions (summons, morphs, faction changes, quest events, AI events
 * between creatures, sounds), spell lists (`creature_template_spells`), immunities.
 */
module dmangos.world.eventai;

import std.random : uniform;

import dmangos.mysql : MySqlConnection;

/// `EventAI_Type`, the ones handled.
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
    range = 9,
    spawned = 11,
    targetHp = 12,
    reachedHome = 21,
    aura = 23,
    missingAura = 27,
}

/// `EventAI_ActionType`, the ones handled.
enum ActionType : ubyte
{
    none = 0,
    text = 1,
    emote = 5,
    randomEmote = 10,
    castSpell = 11,
    combatMovement = 21,
    setPhase = 22,
    incPhase = 23,
    evade = 24,
    fleeForAssist = 25,
    callForHelp = 39,
    setStandState = 47,
    textNew = 54,
    attackStart = 55,
    setRangedMode = 57,
}

/// `EventFlags`
enum uint eventRepeatable = 0x01, eventRandomAction = 0x20, eventRangedModeOnly = 0x100, eventMeleeModeOnly = 0x200,
    eventCombatAction = 0x400;

/// `CastFlags`
enum uint castInterruptPrevious = 0x01, castTriggered = 0x02, castForceCast = 0x04, castNoMeleeIfOom = 0x08,
    castForceTargetSelf = 0x10, castAuraNotPresent = 0x20;

/// `EventAI_Target`, the ones handled.
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
    none = 15,
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
        foreach (row; world.query!"SELECT id, target_id FROM dbscript_random_templates WHERE type = 0"())
            data.textGroups[row.get!uint(0)] ~= cast(uint) row.get!int(1);
        info!"loaded %s creature scripts for %s creatures and %s spawns, %s random text groups"(count,
            data.byCreature.length, data.bySpawn.length, data.textGroups.length);
        return data;
    }

    /// The events of a creature: its entry's, then its spawn's (`CreatureEventAI`'s two maps).
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

/// An event as it stands for one creature (`CreatureEventAIHolder`).
struct EventHolder
{
    const(EventAiEvent)* event;
    uint timer;
    bool enabled = true;
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

    /// The victim's health in percent and distance in yards; uint.max if it has none.
    uint victimHealthPercent();
    float victimDistance(); /// ditto

    /// The target of an action (`GetTargetByType`); 0 if there is none.
    ulong targetFor(int type, ulong invoker);

    /// `DoCastSpellIfCan`: false if it could not.
    bool scriptCast(uint spell, ulong target, uint flags);

    /// `DoDisplayText`: a broadcast text, said, yelled, emoted or whispered as the text says.
    void scriptText(uint text, ulong target);

    /// `HandleEmote`, `SetStandState`
    void scriptEmote(uint emote);
    void scriptStandState(uint state); /// ditto

    /// `DoFlee`, `CallForHelp`, `EnterEvadeMode`, `AttackStart`
    bool scriptFlee();
    void scriptCallForHelp(float radius); /// ditto
    void scriptEvade(); /// ditto
    void scriptAttack(ulong target); /// ditto

    /// `SetCombatMovement`, `SetRangedMode`
    void scriptCombatMovement(bool on);
    void scriptRangedMode(bool on, float distance); /// ditto
    @property bool rangedMode(); /// ditto
}

/// See the module documentation.
final class EventAI
{
    private EventHolder[] holders;
    private const EventAiData data;
    private uint phase;
    private int updateIn = 500;     // `EVENT_UPDATE_TIME`: the timers are looked at twice a second
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
            if (e.type == EventType.timerOutOfCombat || e.type == EventType.missingAura)
                hasOutOfCombatTimers = true;
        }
        resetSpawned();
    }

    /// Whether it needs ticks out of combat: timers there, or its spawn events still to run.
    @property bool wantsTicks() const
    {
        return spawnPending || hasOutOfCombatTimers;
    }

    /// `JustRespawned`: the timers start (in combat ones wait for the fight).
    private void resetSpawned()
    {
        foreach (ref h; holders)
        {
            h.enabled = true;
            h.timer = 0;
            if (h.event.type == EventType.timerOutOfCombat || h.event.type == EventType.timerInCombat)
                setTimer(h, h.event.params[0], h.event.params[1]);
        }
    }

    /// `UpdateRepeatTimer`
    private static void setTimer(ref EventHolder h, int min, int max)
    {
        if (min == max)
            h.timer = min > 0 ? min : 0;
        else if (max > min)
            h.timer = uniform!"[]"(min, max);
        else
            h.enabled = false;
    }

    /// `IsTimerBasedEvent`'s repeat timers (`GetRepeatTimers`): most events' third and fourth parameters.
    private static void repeatTimers(const ref EventAiEvent e, out int min, out int max)
    {
        if (e.type == EventType.kill)
        {
            min = e.params[0];
            max = e.params[1];
        }
        else
        {
            min = e.params[2];
            max = e.params[3];
        }
    }

    /// `CheckEvent`: whether the event may go now.
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
        case EventType.aura:
            return me.hasOwnAura(e.params[0]);
        case EventType.missingAura:
            return !me.hasOwnAura(e.params[0]);
        default:
            return true;
        }
    }

    /// `ProcessEvent`: by its chance, its actions (one at random with `EFLAG_RANDOM_ACTION`), then its reset.
    private void process(ref EventHolder h, Scripted me, ulong invoker)
    {
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
                success = act(e.actions[actions[uniform(0, actions.length)]], me, invoker);
        }
        else
        {
            success = act(e.actions[0], me, invoker);
            if (!(e.flags & eventCombatAction) || success)
                foreach (ref a; e.actions[1 .. $])
                    act(a, me, invoker);
        }
        if (!(e.flags & eventCombatAction) || success)
            reset(h);
    }

    /// `ResetEvent`: timer-based events wait their repeat time; those that do not repeat are done.
    private void reset(ref EventHolder h)
    {
        const e = h.event;
        switch (e.type)
        {
        case EventType.spawned, EventType.death, EventType.aggro, EventType.evade, EventType.reachedHome:
            h.enabled = false; // `IsRepeatableEvent`: never again
            return;
        default:
            break;
        }
        int min, max;
        repeatTimers(*e, min, max);
        switch (e.type)
        {
        case EventType.timerInCombat, EventType.timerOutOfCombat, EventType.hp, EventType.mana, EventType.kill,
                EventType.range, EventType.targetHp, EventType.aura, EventType.missingAura:
            setTimer(h, min, max);
            break;
        default:
            break;
        }
        if (!(e.flags & eventRepeatable))
            h.enabled = false;
    }

    /// `ProcessAction`
    private bool act(const ref EventAiAction a, Scripted me, ulong invoker)
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
            const target = me.targetFor(a.params[1], invoker);
            if (target == 0 && a.params[1] != EventTarget.none)
                return false;
            return me.scriptCast(a.params[0], target, cast(uint) a.params[2]);
        }
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
            const target = me.targetFor(a.params[0], invoker);
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

    /// Runs the events of `type` now (`CheckAndReadyEventForExecution` then `ProcessEvents`).
    private void fire(EventType type, Scripted me, ulong invoker)
    {
        foreach (ref h; holders)
            if (h.event.type == type && check(h, me))
                process(h, me, invoker);
    }

    // -------------------------------------------------------------------
    // The AI's moments
    // -------------------------------------------------------------------

    /// `EnterCombat`: the in-combat timers start, and the aggro events go.
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
        fire(EventType.aggro, me, enemy);
        updateIn = 500;
        pendingDiff = 0;
    }

    /// `KilledUnit`
    void killed(Scripted me, ulong victim)
    {
        fire(EventType.kill, me, victim);
    }

    /// `JustDied`
    void died(Scripted me, ulong killer)
    {
        fire(EventType.death, me, killer);
    }

    /// `EnterEvadeMode`: the evade events, then `Reset`.
    void evaded(Scripted me)
    {
        fire(EventType.evade, me, 0);
        phase = 0;
        foreach (ref h; holders)
            switch (h.event.type)
            {
            case EventType.timerInCombat, EventType.aggro:
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

    /// `JustReachedHome`
    void reachedHome(Scripted me)
    {
        fire(EventType.reachedHome, me, 0);
    }

    /// `UpdateEventTimers`, twice a second; the spawned events at the first.
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
                    EventType.targetHp, EventType.range, EventType.aura, EventType.missingAura:
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
        uint victimHealthPercent() { return 100; }
        float victimDistance() { return 2; }
        ulong targetFor(int type, ulong invoker) { return type == EventTarget.self ? 1 : 2; }
        bool scriptCast(uint spell, ulong target, uint flags) { cast_ ~= spell; return true; }
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
}
