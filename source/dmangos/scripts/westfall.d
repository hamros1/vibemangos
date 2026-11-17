/**
 * Westfall: the Defias Traitor, who leads the player who takes "The Defias Brotherhood" (155) from
 * Sentinel Hill to the Deadmines' hidden entrance in Moonbrook along his escort path.
 */
module dmangos.scripts.westfall;

import dmangos.script;

/**
 * The Defias Traitor: taken on the quest, he says so and sets off; at Moonbrook he warns of thieves;
 * at the hideout he tells the player to report to Stoutmantle (the quest's event), waits, and goes.
 * Attacked on the way he calls for help; left behind or killed, the quest fails.
 */
@creature("npc_defias_traitor")
struct DefiasTraitor
{
    enum uint questDefiasBrotherhood = 155;
    enum : int
    {
        sayStart = -1000101,
        sayMoonbrook = -1000102,
        sayHideout = -1000103,
        sayAggro1 = -1000104,
        sayAggro2 = -1000105,
    }
    enum uint moonbrookPoint = 36; // the path's point 37; the hideout is its last

    Escort escort = { despawnAfterMs: 3000 }; // over, he goes back to Sentinel Hill

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questDefiasBrotherhood || escort.active)
            return;
        me.say(sayStart, e.player);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == moonbrookPoint)
            me.say(sayMoonbrook, escort.player);
        else if (point != uint.max && point + 1 == me.waypointCount)
        {
            me.say(sayHideout, escort.player);
            me.questEvent(escort.player, escort.quest);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (escort.active)
            me.say(me.random(2) ? sayAggro1 : sayAggro2, escort.player);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}
