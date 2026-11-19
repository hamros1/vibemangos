/**
 * Redridge Mountains: Corporal Keeshan, whom the player on "Missing In Action" (219) leads out of
 * Blackrock territory back to Lakeshire along his escort path.
 */
module dmangos.scripts.redridge;

import dmangos.script;

/// `FACTION_ESCORT_A_NEUTRAL_ACTIVE`: an Alliance escort that monsters attack and that fights back.
enum uint factionEscortAllianceActive = 231;

/**
 * Corporal Keeshan: taken on the quest, he thanks the player and sets off; outside he sits down for a
 * rest, gets up again, and at Lakeshire reports to Marshal Marris (the quest's event) and says
 * goodbye. Left behind or killed, the quest fails. The points are those of his `script_waypoint`
 * path (the database's, counted from 1).
 */
@creature("npc_corporal_keeshan")
struct CorporalKeeshan
{
    enum uint questMissingInAction = 219;
    /// `broadcast_text` rows.
    enum : uint { sayStart = 25, sayRest = 26, sayRested = 27, sayReport = 29, sayThanks = 30 }
    /// Points of his path.
    enum : uint { restPoint = 26, onFromRest = 27, reportPoint = 53, goodbyePoint = 54 }

    Escort escort = { despawnAfterMs: 5000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questMissingInAction || escort.active)
            return;
        me.sayText(sayStart, e.player);
        me.setFaction(factionEscortAllianceActive);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case restPoint:
            me.standState(StandState.sit);
            me.sayText(sayRest, escort.player);
            break;
        case onFromRest:
            me.standState(StandState.stand);
            me.sayText(sayRested, escort.player);
            break;
        case reportPoint:
            me.sayText(sayReport, escort.player);
            me.questEvent(escort.player, escort.quest);
            break;
        case goodbyePoint:
            me.sayText(sayThanks, escort.player);
            break;
        default:
            break;
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

    auto k = Driven!(dmangos.scripts.redridge).make("npc_corporal_keeshan");
    k.host.pathLength = 54;
    k.raise(QuestAccepted(k.host.player, 219));
    assert(k.host.did("text 25") && k.host.faction == 231 && k.host.lastPoint == 0);
    k.walk(25); // the database's point 26
    assert(k.host.did("stand 1") && k.host.did("text 26"));
    k.walk();
    assert(k.host.did("stand 0") && k.host.did("text 27") && k.host.did("event 219") && k.host.did("text 30"));
    assert(k.host.did("despawn") && !k.host.did("fail 219"));

    // Killed on the way: the quest fails.
    auto k2 = Driven!(dmangos.scripts.redridge).make("npc_corporal_keeshan");
    k2.raise(QuestAccepted(k2.host.player, 219));
    k2.arrive();
    k2.raise(Died());
    assert(k2.host.did("fail 219") && !k2.host.did("event 219"));
}
