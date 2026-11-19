/**
 * Loch Modan: Miran, whose shipment the player on "Protecting the Shipment" (309) guards on the way
 * to the Stonewrought Dam, where two Dark Iron Raiders ambush it.
 */
module dmangos.scripts.lochmodan;

import dmangos.script;

/**
 * Miran: he walks his path (`script_waypoint`, points counted from 1); near the end he cries for
 * help, two raiders come at him and he waits until both are dead; at the last point the quest's
 * event happens and he goes a little later. Left behind or killed, the quest fails.
 */
@creature("npc_miran")
struct Miran
{
    enum uint questProtectingTheShipment = 309, darkIronRaider = 2149;
    /// `broadcast_text` rows.
    enum : uint { sayHelp = 510, sayRaidersDead = 511, sayArrived = 498, sayRaider = 512 }
    /// Points of his path: the cry, the ambush, the end.
    enum : uint { helpPoint = 18, ambushPoint = 19, endPoint = 23 }

    Escort escort = { despawnAfterMs: 15_000 };
    ubyte raiders; /// of the ambush, alive

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questProtectingTheShipment || escort.active)
            return;
        raiders = 0;
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case helpPoint:
            me.sayText(sayHelp);
            break;
        case ambushPoint:
            escort.paused = true;
            static immutable Location[2] ambush = [Location(-5705.012f, -3736.6575f, 318.56738f, 0.57595f),
                Location(-5696.1943f, -3736.78f, 318.58145f, 2.40855f)];
            foreach (at; ambush)
                if (const raider = me.summon(darkIronRaider, at, 25_000, me.self))
                {
                    ++raiders;
                    me.sayAs(raider, sayRaider);
                }
            if (!raiders)
                escort.paused = false;
            break;
        case endPoint:
            me.sayText(sayArrived);
            me.questEvent(escort.player, escort.quest);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.summoned.entry != darkIronRaider || raiders == 0)
            return;
        if (--raiders == 0)
        {
            me.sayText(sayRaidersDead);
            escort.paused = false;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

unittest
{
    import dmangos.scripts.testhost : Driven;

    auto m = Driven!(dmangos.scripts.lochmodan).make("npc_miran");
    m.host.pathLength = 24;
    m.raise(QuestAccepted(m.host.player, 309));
    m.walk();
    assert(m.host.did("text 510") && m.host.did("summon 2149") && m.host.did("text of 2149 512"));
    m.tick(60_000);
    assert(m.host.lastPoint == uint.max, "waits for the raiders");
    m.raise(SummonedDied(EntityRef(0xF130_0000_0000_0000 | (ulong(2149) << 24) | 1)));
    assert(!m.host.did("text 511"));
    m.raise(SummonedDied(EntityRef(0xF130_0000_0000_0000 | (ulong(2149) << 24) | 2)));
    assert(m.host.did("text 511"));
    m.tick(100);
    m.walk();
    assert(m.host.did("text 498") && m.host.did("event 309") && !m.host.did("fail 309"));
}
