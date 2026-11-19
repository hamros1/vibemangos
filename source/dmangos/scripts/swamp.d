/**
 * Swamp of Sorrows: Galen Goodward, caged at the Fallow Sanctuary, whom the player on "Galen's
 * Escape" (1393) frees and leads away.
 */
module dmangos.scripts.swamp;

import dmangos.script;

/**
 * Galen Goodward: caged, he cries for help every few seconds. Taken on the quest, his cage opens and
 * he walks (`script_waypoint`, points counted from 1), at the end runs, whispers his thanks (the
 * quest's event), and disappears. Left behind or killed, the quest fails.
 */
@creature("npc_galen_goodward")
struct GalenGoodward
{
    enum uint questGalensEscape = 1393, cage = 37118;
    enum uint factionEscortNeutralActive = 250;
    enum : int
    {
        sayPeriodic = -1000582, sayQuestAccepted = -1000583, sayAttacked1 = -1000584, sayAttacked2 = -1000585,
        sayQuestComplete = -1000586, emoteWhisper = -1000587, emoteDisappear = -1000588,
    }
    enum : uint { runPoint = 20, completePoint = 21, disappearPoint = 22, lastPoint = 23 }

    enum Step : ubyte { cry }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.every(Step.cry, 6.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!escort.active && !me.inCombat)
            me.say(sayPeriodic);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questGalensEscape || escort.active)
            return;
        if (const c = me.objectNearby(cage, 10))
            me.useObject(c);
        escort.start(me, e.player, e.quest);
        me.setFaction(factionEscortNeutralActive);
        me.say(sayQuestAccepted);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case runPoint:
            escort.run = true;
            break;
        case completePoint:
            me.say(sayQuestComplete, escort.player);
            me.say(emoteWhisper, escort.player);
            me.questEvent(escort.player, escort.quest);
            break;
        case disappearPoint:
            me.say(emoteDisappear);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (escort.active)
            me.say(me.random(2) ? sayAttacked1 : sayAttacked2, e.enemy);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

unittest
{
    import dmangos.scripts.testhost : Driven;

    auto g = Driven!(dmangos.scripts.swamp).make("npc_galen_goodward");
    g.raise(Spawned());
    g.tick(6000);
    assert(g.host.did("say -1000582"));
    g.host.pathLength = 23;
    g.host.nearby[37118] = EntityRef(0xF110_0000_0000_0000 | (ulong(37118) << 24) | 1);
    g.raise(QuestAccepted(g.host.player, 1393));
    assert(g.host.did("use 37118") && g.host.faction == 250 && g.host.did("say -1000583"));
    g.walk();
    assert(g.host.did("event 1393") && g.host.did("say -1000588") && g.host.did("despawn"));
}
