/**
 * Teldrassil: Mist, the lost nightsaber cub, who follows the player home to Sentinel Arynia
 * Cloudsbreak ("Mist", 938).
 */
module dmangos.scripts.teldrassil;

import dmangos.script;

/// Mist: follows the player; near Arynia, she is home (the quest's event).
@creature("npc_mist")
struct Mist
{
    enum uint questMist = 938, arynia = 3519, factionDarnassus = 79;
    enum : int { sayAtHome = -1000323, emoteAtHome = -1000324 }

    enum Step : ubyte { look }
    Schedule!Step steps;
    Follower follower;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questMist || follower.active)
            return;
        follower.start(me, e.player, e.quest, factionDarnassus);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!follower.active)
            return steps.clear();
        if (me.inCombat)
            return;
        const aryniaRef = me.creatureNearby(arynia, 10);
        if (!aryniaRef)
            return;
        me.sayFrom(aryniaRef, sayAtHome);
        me.say(emoteAtHome);
        if (me.questStatus(follower.player, questMist) == QuestProgress.incomplete)
            me.groupQuestEvent(follower.player, questMist);
        follower.complete(me);
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        follower.fail(me);
        steps.clear();
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.teldrassil;

    auto m = Driven!self("npc_mist", 3568);
    m.host.quests[Mist.questMist] = QuestProgress.incomplete;
    m.raise(QuestAccepted(hero, Mist.questMist));
    assert(m.host.has("faction 79") && m.host.has("follow"));
    m.run(3000);
    assert(!m.host.has("event 938"));
    m.host.nearby[Mist.arynia] = creatureRef(Mist.arynia);
    m.run(1000);
    assert(m.host.has("say as 3519 -1000323") && m.host.has("event 938") && m.host.has("despawn"));
}
