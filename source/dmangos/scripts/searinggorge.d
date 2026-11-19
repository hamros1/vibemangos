/**
 * Searing Gorge: Dorius Stonetender, lying wounded until the player on "Suntara Stones" (3367) helps
 * him to the Cauldron and on; a Dark Iron Marksman shoots him at the end.
 */
module dmangos.scripts.searinggorge;

import dmangos.script;

/**
 * Dorius Stonetender: he walks his sniffed path (`waypoint_path` 8284, points counted from 1), whose
 * points' scripts do most of the scene (his lines, the Dark Iron Steelshifters' ambushes, and the
 * marksman at the end); he shows the player the Cauldron, and when the marksman's shot hits him the
 * quest's event happens and his death scene (relay script 8284) plays. Left behind or killed, the
 * quest fails.
 */
@creature("npc_dorius_stonetender")
struct DoriusStonetender
{
    enum uint questSuntaraStones = 3367, spellMarksmanHit = 12198, relayFinished = 8284;
    enum uint factionEscortAllianceActive = 231;
    /// `broadcast_text` rows.
    enum : uint { sayAggro1 = 4351, sayToPlayer = 4354 }
    enum : uint { cauldronPoint = 37, facePoint = 53 }
    enum uint emotePoint = 25;

    Escort escort = { despawnAfterMs: 300_000, runScripts: true }; // done, his relay script takes him away
    bool shot;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!escort.active)
            me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questSuntaraStones || escort.active)
            return;
        me.standState(StandState.stand);
        me.setFaction(factionEscortAllianceActive);
        shot = false;
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case cauldronPoint:
            me.sayText(sayToPlayer, escort.player);
            me.emote(emotePoint);
            break;
        case facePoint:
            me.face(escort.player);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        // The shot comes as he reaches the end of his path, or a moment after.
        if (e.spell != spellMarksmanHit || shot || !(escort.active || escort.finished))
            return;
        shot = true;
        me.questEvent(escort.player, escort.quest);
        me.relay(relayFinished, e.caster);
        escort.active = false; // the relay script ends the scene
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.sayText(sayAggro1 + me.random(3), e.enemy);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    auto d = Driven!(dmangos.scripts.searinggorge).make("npc_dorius_stonetender");
    d.raise(Spawned());
    assert(d.host.did("stand 7"));
    d.host.pathLength = 83;
    d.raise(QuestAccepted(d.host.player, 3367));
    assert(d.host.did("stand 0") && d.host.faction == 231);
    d.walk(82);
    assert(d.host.did("text 4354") && d.host.did("emote 25") && d.host.did("face"));
    d.raise(SpellHit(creatureRef(8338), 12198));
    assert(d.host.did("event 3367") && d.host.did("relay 8284") && !d.host.did("fail 3367"));
}
