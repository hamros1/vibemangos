/**
 * Razorfen Downs (map 129): the gong that calls Tuten'kash (three rings: eight Tomb Fiends, four
 * Tomb Reavers, then Tuten'kash himself, each wave to be slain before the gong rings again), and
 * Belnistrasz, who is escorted to the idol for "Extinguishing the Idol" (quest 3525) and holds a
 * ritual there for three minutes while the quilboar come in waves; his brazier, to which the quest
 * is turned in, appears when it is over.
 */
module dmangos.scripts.razorfendowns;

import dmangos.script;

/// Creatures and objects of the downs.
enum : uint
{
    tombFiend = 7349,
    tombReaver = 7351,
    tutenKash = 7355,
    belnistrasz = 8516,
    witheredBattleBoar = 7333,
    witheredQuilguard = 7329,
    geomancer = 7335,
    plaguemaw = 7356,
    gong = 148917,
    brazier = 152097,
}

/// The gong's event (`scripted_event_id`: event_go_tutenkash_gong).
enum uint gongEvent = 3130;

/// What the downs remember: the waves called, and whether Tuten'kash is dead (`instance.data`).
@instance("instance_razorfen_downs")
struct RazorfenDowns
{
    enum Signals : uint { ritualOver = 100 }

    ubyte wave;      /// waves called so far
    bool tutenKashDead;
    Pack!8 summoned; /// the wave under way
    @transient EntityRef gongRef;

    /// The corridors they come from, by turns.
    static immutable Location[2] corridors = [
        Location(2484.83f, 811.11f, 43.40f, 1.67f), Location(2546.03f, 902.77f, 47.16f, 5.04f),
    ];
    static immutable uint[3] waveEntry = [tombFiend, tombReaver, tutenKash];
    static immutable ubyte[3] waveSize = [8, 4, 1];

    void on(ref InstanceContext downs, const ref ObjectLoaded e)
    {
        if (e.object.entry == gong)
            gongRef = e.object;
    }

    void on(ref InstanceContext downs, const ref EventHappened e)
    {
        if (e.event != gongEvent || tutenKashDead || summoned.alive > 0 || wave >= waveEntry.length)
            return;
        summoned.clear();
        foreach (i; 0 .. waveSize[wave])
        {
            Location at = corridors[i % 2];
            at.x += (cast(int) downs.random(9) - 4) * 0.5f;
            at.y += (cast(int) downs.random(9) - 4) * 0.5f;
            if (const made = downs.summon(waveEntry[wave], at, 0, e.source))
                summoned.add(made);
        }
        ++wave;
        if (e.target)
            gongRef = e.target;
        if (gongRef)
            downs.objectFlags(gongRef, ObjectFlag.noInteract);
    }

    void on(ref InstanceContext downs, const ref CreatureDied e)
    {
        if (e.creature.entry == tutenKash)
            tutenKashDead = true;
        if (summoned.died(e.creature) && summoned.allDead && !tutenKashDead && gongRef)
            downs.objectFlags(gongRef, 0, ObjectFlag.noInteract); // it may be rung again
    }

    void on(ref InstanceContext downs, const ref Signal e)
    {
        if (e.id == Signals.ritualOver)
            downs.spawnObjects(brazier, 3600);
    }
}

/// Belnistrasz: see the module documentation.
@creature("npc_belnistrasz")
struct Belnistrasz
{
    enum uint quest = 3525;
    enum : int
    {
        sayReady = -1129005, sayStartRitual = -1129006, sayAggro1 = -1129007, sayAggro2 = -1129008,
        say3Min = -1129009, say2Min = -1129010, say1Min = -1129011, sayFinish = -1129012,
    }
    enum : uint { fireball = 9053, frostNova = 11831, idolShutdown = 12774, idolRoomShake = 12816 }

    /// Where the quilboar come in.
    static immutable Location[3] spawners = [
        Location(2582.79f, 954.392f, 52.4821f, 3.78736f), Location(2569.42f, 956.380f, 52.2732f, 5.42797f),
        Location(2570.62f, 942.393f, 53.7433f, 0.71558f),
    ];

    enum Step : ubyte { ritual, fireball, frostNova }
    Schedule!Step steps;
    Escort escort;
    ubyte ritualPhase;
    bool inRitual, spoke;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != quest || escort.active)
            return;
        escort.start(me, e.player, quest, true);
        me.say(sayReady, e.player);
        me.setFaction(250); // FACTION_ESCORT_N_NEUTRAL_ACTIVE
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (escort.reached(me, e) + 1 == 24) // the database's points count from 1
        {
            me.say(sayStartRitual);
            escort.paused = true;
            inRitual = true;
            ritualPhase = 0;
            steps.after(Step.ritual, 1.seconds);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (inRitual)
        {
            if (!spoke)
                me.say(me.random(2) ? sayAggro1 : sayAggro2, e.enemy);
            spoke = true;
            return;
        }
        steps.every(Step.fireball, 1.seconds, 2500.msecs);
        steps.every(Step.frostNova, 6.seconds, 12.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.fireball:
            if (me.inCombat && !inRitual)
                me.castSpell(fireball);
            break;
        case Step.frostNova:
            if (me.inCombat && !inRitual)
                me.castSpell(frostNova);
            break;
        case Step.ritual:
            ritual(me);
            break;
        }
    }

    /// One phase of the ritual; the next follows after its time.
    private void ritual(ref CreatureContext me)
    {
        static immutable uint[11] waitMs = [1000, 39_000, 20_000, 20_000, 40_000, 40_000, 20_000, 40_000, 20_000, 3000, 0];
        const phase = ritualPhase++;
        switch (phase)
        {
        case 0:
            me.castSelf(idolShutdown);
            break;
        case 1, 2, 4, 6, 8:
            wave(me, phase);
            break;
        case 3:
            me.say(say3Min, me.self);
            break;
        case 5:
            wave(me, phase);
            me.say(say2Min, me.self);
            break;
        case 7:
            me.say(say1Min, me.self);
            break;
        case 9:
            me.say(sayFinish, me.self);
            break;
        case 10:
            inRitual = false;
            me.questEvent(escort.player, quest);
            me.signalDungeon(RazorfenDowns.Signals.ritualOver);
            me.removeAura(idolShutdown);
            me.castSelf(idolRoomShake);
            escort.resume();
            return;
        default:
            return;
        }
        steps.after(Step.ritual, waitMs[phase].msecs);
    }

    /// Quilboar at one of the spawners (after the first minute's waves, Plaguemaw the Rotting).
    private void wave(ref CreatureContext me, uint phase)
    {
        const at = spawners[me.random(3)];
        if (phase > 7)
        {
            me.summon(plaguemaw, at, 60_000, me.self);
            return;
        }
        foreach (entry; [witheredBattleBoar, witheredBattleBoar, witheredQuilguard, geomancer])
            me.summon(entry, at, 60_000, me.self);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        inRitual = false;
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.setFaction(0);
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.razorfendowns;
    auto downs = runInstance!self("instance_razorfen_downs");
    const ringer = playerRef(), theGong = objectRef(gong);
    downs.raise(ObjectLoaded(theGong));
    downs.raise(EventHappened(gongEvent, ringer, theGong));
    assert(downs.host.times("summon 7349") == 8 && downs.host.done("object flags 148917 +10 -0"));
    downs.raise(EventHappened(gongEvent, ringer, theGong));
    assert(downs.host.times("summon 7349") == 8, "not while the wave lives");
    foreach (spawn; 1 .. 9)
        downs.raise(CreatureDied(creatureRef(tombFiend, 1000 + spawn)));
    assert(downs.host.done("object flags 148917 +0 -10"));
    downs.raise(EventHappened(gongEvent, ringer, theGong));
    assert(downs.host.times("summon 7351") == 4);
    foreach (spawn; 9 .. 13)
        downs.raise(CreatureDied(creatureRef(tombReaver, 1000 + spawn)));
    downs.raise(EventHappened(gongEvent, ringer, theGong));
    assert(downs.host.times("summon 7355") == 1);
    downs.raise(CreatureDied(creatureRef(tutenKash, 1013)));
    downs.raise(EventHappened(gongEvent, ringer, theGong));
    assert(downs.host.times("summon 7355") == 1 && downs.state!RazorfenDowns.tutenKashDead);

    auto bel = runCreature!self("npc_belnistrasz", belnistrasz);
    foreach (i; 0 .. 25)
        bel.host.path ~= Waypoint(Location(i, 0, 0));
    bel.raise(QuestAccepted(playerRef, Belnistrasz.quest));
    foreach (point; 0 .. 24)
    {
        bel.host.walking = false;
        bel.raise(MovementDone(point));
        bel.run(250);
    }
    assert(bel.host.done("say -1129006") && !bel.host.done("move 24"), "the ritual holds him at point 24");
    bel.run(250_000);
    assert(bel.host.done("cast 12774") && bel.host.done("say -1129012") && bel.host.done("quest event 3525"));
    assert(bel.host.done("dungeon 100 0") && bel.host.done("unaura 12774") && bel.host.done("summon 7356"));
    bel.host.walking = false;
    bel.run(500);
    assert(bel.host.done("move 24"), "and on he goes");
}
