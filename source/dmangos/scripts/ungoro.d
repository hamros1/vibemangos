/**
 * Un'Goro Crater: the scent of Lar'korwi's mate, which the hunter on "The Scent of Lar'korwi"
 * (4291) follows from spot to spot until the mate comes out; the escort of A-Me 01 ("Chasing A-Me
 * 01", 4245); Ringo, who faints on the way to Spraggle ("A Little Help From My Friends", 4491); and
 * Simone the Inconspicuous, who is Simone the Seductress with Precious the Devourer, for a hunter on
 * "Stave of the Ancients" (7636) to fight alone.
 */
module dmangos.scripts.ungoro;

import dmangos.script;

/// A scent spot: walked into on the quest, the mate comes out there, unless it is out already.
@areaTrigger("at_scent_larkorwi")
struct ScentOfLarkorwi
{
    enum uint questScent = 4291, larkorwiMate = 9683;

    void on(ref AreaTriggerContext spot, const ref TriggerEntered e)
    {
        if (spot.questStatus(e.player, questScent) != QuestProgress.incomplete)
            return;
        if (spot.creatureNear(larkorwiMate, e.at, 25))
            return;
        spot.summon(larkorwiMate, e.at, 2 * 60_000, e.player); // it goes two minutes after a fight
    }
}

/// A-Me 01: led home through the crater; it remarks on what attacks it.
@creature("npc_ame01")
struct Ame01
{
    enum uint questChasingAme = 4245;
    enum : int { sayStart = -1000446, sayProgress = -1000447, sayEnd = -1000448, sayAggro1 = -1000449 }

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questChasingAme || escort.active)
            return;
        me.standState(StandState.stand);
        me.setFaction(EscortFaction.neutralFriendPassive);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point + 1 == 1)
            me.say(sayStart);
        else if (point + 1 == 20)
            me.say(sayProgress);
        else if (point + 1 == 38)
        {
            me.say(sayEnd);
            me.groupQuestEvent(escort.player, questChasingAme);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (escort.active && !e.enemy.isPlayer)
            me.say(sayAggro1 - cast(int) me.random(3), e.enemy);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Ringo: follows the player to Spraggle Frock, fainting now and then (the water of the Un'Goro
 * soil revives him); at Spraggle's, a little talk.
 */
@creature("npc_ringo")
struct Ringo
{
    enum uint questALittleHelp = 4491, spraggle = 9997, spellReviveRingo = 15591;
    enum : int
    {
        sayStart1 = -1000416, sayFaint1 = -1000418, sayWake1 = -1000422, sayEnd1 = -1000426, sayEnd2 = -1000427,
        sayEnd3 = -1000428, emoteEnd4 = -1000429, emoteEnd5 = -1000430, sayEnd6 = -1000431, sayEnd7 = -1000432,
        emoteEnd8 = -1000433,
    }

    enum Step : ubyte { faint, look, talk }
    Schedule!Step steps;
    Follower follower;
    EntityRef spraggleRef;
    ubyte talk;
    bool fainted;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questALittleHelp || follower.active)
            return;
        me.standState(StandState.stand);
        follower.start(me, e.player, e.quest, EscortFaction.neutralFriendPassive);
        fainted = false;
        talk = 0;
        steps.after(Step.faint, (30 + me.random(31)).seconds);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == spellReviveRingo && follower.active && fainted)
            wake(me, true);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.faint:
            if (!follower.active)
                return;
            if (me.inCombat || fainted)
                return cast(void) steps.after(Step.faint, 5.seconds);
            faint(me, true);
            break;
        case Step.look:
            if (!follower.active)
                return steps.cancel(Step.look);
            if (me.inCombat)
                return;
            if (const s = me.creatureNearby(spraggle, 5))
            {
                if (me.questStatus(follower.player, questALittleHelp) == QuestProgress.incomplete)
                    me.groupQuestEvent(follower.player, questALittleHelp);
                spraggleRef = s;
                follower.complete(me, true);
                if (fainted)
                    wake(me, false);
                steps.clear();
                steps.after(Step.talk, 1.seconds);
            }
            break;
        case Step.talk:
            if (!me.alive(spraggleRef))
                return me.despawn(1000);
            switch (++talk)
            {
            case 1: me.say(sayEnd1); steps.after(Step.talk, 3.seconds); break;
            case 2: me.sayFrom(spraggleRef, sayEnd2); steps.after(Step.talk, 5.seconds); break;
            case 3: me.say(sayEnd3); steps.after(Step.talk, 1.seconds); break;
            case 4: me.say(emoteEnd4); faint(me, false); steps.after(Step.talk, 9.seconds); break;
            case 5: me.say(emoteEnd5); wake(me, false); steps.after(Step.talk, 1.seconds); break;
            case 6: me.say(sayEnd6); steps.after(Step.talk, 3.seconds); break;
            case 7: me.sayFrom(spraggleRef, sayEnd7); steps.after(Step.talk, 10.seconds); break;
            case 8: me.say(emoteEnd8); steps.after(Step.talk, 5.seconds); break;
            default: me.despawn(1000); break;
            }
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        follower.fail(me);
        steps.clear();
    }

    private void faint(ref CreatureContext me, bool onTheWay)
    {
        fainted = true;
        if (onTheWay)
        {
            follower.pause(me, true);
            me.say(sayFaint1 - cast(int) me.random(4));
        }
        me.standState(StandState.sleep);
    }

    private void wake(ref CreatureContext me, bool onTheWay)
    {
        fainted = false;
        me.standState(StandState.stand);
        if (!onTheWay)
            return;
        me.say(sayWake1 - cast(int) me.random(4));
        follower.pause(me, false);
        steps.after(Step.faint, (60 + me.random(61)).seconds);
    }
}

/// The Stave of the Ancients' demons of Un'Goro.
private enum : uint
{
    simoneInconspicuous = 14527,
    simoneSeductress = 14533,
    precious = 14528,
    preciousDevourer = 14538,
    theCleaner = 14503,
    questStaveOfTheAncients = 7636,
}

/**
 * Simone the Inconspicuous: asked by a hunter on the quest, she laughs, shouts, and shows herself as
 * Simone the Seductress, her dog Precious as Precious the Devourer.
 */
@creature("npc_simone_the_inconspicuous")
struct SimoneTheInconspicuous
{
    enum uint showFace = 1, emoteLaugh = 11, emoteShout = 22, gossipFlag = 1;

    enum Step : ubyte { shout, transform }
    Schedule!Step steps;
    EntityRef player;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.npcFlags(gossipFlag);
        if (!me.creatureNearby(precious, 100))
            me.summon(precious);
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questStaveOfTheAncients) != QuestProgress.incomplete)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "I am not fooled by your disguise, temptress. Your time to die has come.", showFace);
        me.sendGossip(e.player, 0, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != showFace || player)
            return;
        me.closeGossip(e.player);
        player = e.player;
        me.follow(EntityRef.init);
        me.npcFlags(0);
        me.emote(emoteLaugh);
        steps.after(Step.shout, 5.seconds);
        steps.after(Step.transform, 10.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shout:
            me.emote(emoteShout);
            break;
        case Step.transform:
            Location dogAt;
            const dog = me.creatureNearby(precious, 100);
            if (dog && me.locationOf(dog, dogAt))
            {
                me.summon(preciousDevourer, dogAt);
                me.despawn(dog);
            }
            me.summon(simoneSeductress, me.location);
            me.despawn(1);
            break;
        }
    }
}

/**
 * Simone the Seductress: Temptress' Kiss and Chain Lightning; Viper Sting silences her. One hunter
 * fights her: anyone else joining in, she and her dog go, and The Cleaner comes. Unfought for twenty
 * minutes, she goes.
 */
@creature("npc_simone_seductress")
struct SimoneSeductress
{
    enum : uint { spellChainLightning = 23206, spellTemptressKiss = 23205, spellSilence = 23207, spellViperSting3 = 14280 }
    enum int emoteSilence = -1001250;

    enum Step : ubyte { kiss, lightning, leave }
    Schedule!Step steps;
    EntityRef hunter;
    bool leaving;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.after(Step.leave, 20 * 60.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (const dog = me.creatureNearby(preciousDevourer, 40))
            me.attackBy(dog, e.enemy);
        if (!claim(me, e.enemy))
            return;
        steps.after(Step.kiss, (3 + me.random(4)).seconds);
        steps.after(Step.lightning, (3 + me.random(4)).seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        claim(me, e.attacker);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        // A second player at her dog (`PreciousTheDevourer`).
        if (e.id == 1)
            leave(me, true);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == spellViperSting3 && me.castSelf(spellSilence, true) == ActionResult.ok)
            me.say(emoteSilence);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.kiss:
            if (me.inCombat)
                steps.after(Step.kiss, me.castSpell(spellTemptressKiss) == ActionResult.ok ? 45.seconds : 1.seconds);
            break;
        case Step.lightning:
            if (me.inCombat)
                steps.after(Step.lightning, me.castSpell(spellChainLightning) == ActionResult.ok
                    ? (8 + me.random(5)).seconds : 1.seconds);
            break;
        case Step.leave:
            if (me.inCombat)
                return cast(void) steps.after(Step.leave, 10.seconds);
            leave(me, false);
            break;
        }
    }

    /// Whether `who` may fight her: the first player to, and only that one (pets are their hunter's help).
    private bool claim(ref CreatureContext me, EntityRef who)
    {
        if (!who.isPlayer || leaving)
            return !leaving;
        if (!hunter)
            hunter = who;
        if (who == hunter)
            return true;
        leave(me, true, who);
        return false;
    }

    private void leave(ref CreatureContext me, bool cleaner, EntityRef intruder = EntityRef.init)
    {
        if (leaving)
            return;
        leaving = true;
        if (cleaner)
        {
            const c = me.summon(theCleaner, Location.init, 20 * 60_000);
            if (intruder)
                me.attackBy(c, intruder);
            if (hunter)
                me.attackBy(c, hunter);
        }
        if (const dog = me.creatureNearby(preciousDevourer, 60))
            me.despawn(dog);
        steps.clear();
        me.despawn(1);
    }
}

/// Precious the Devourer: fights with Simone; a second player at it makes her leave.
@creature("npc_precious_the_devourer")
struct PreciousTheDevourer
{
    EntityRef first;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (const simone = me.creatureNearby(simoneSeductress, 40))
            me.attackBy(simone, e.enemy);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!e.attacker.isPlayer)
            return;
        if (!first)
            first = e.attacker;
        else if (e.attacker != first)
            if (const simone = me.creatureNearby(simoneSeductress, 60))
                me.signal(simone, 1);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (!me.creatureNearby(simoneSeductress, 100))
            me.despawn(1);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.ungoro;

    auto a = Driven!self("npc_ame01", 9623, 40);
    a.raise(QuestAccepted(hero, Ame01.questChasingAme));
    a.walkTo(37);
    assert(a.host.has("say -1000446") && a.host.has("event 4245"));

    // Ringo: faints, the water revives him, Spraggle's talk.
    auto r = Driven!self("npc_ringo", 9999);
    r.host.quests[Ringo.questALittleHelp] = QuestProgress.incomplete;
    r.raise(QuestAccepted(hero, Ringo.questALittleHelp));
    r.run(30_000);
    assert(r.host.has("stand 3") && r.host.has("unfollow"));
    r.raise(SpellHit(hero, Ringo.spellReviveRingo));
    assert(r.host.has("say -1000422"));
    r.host.nearby[Ringo.spraggle] = creatureRef(Ringo.spraggle);
    r.run(1000);
    assert(r.host.has("event 4491"));
    r.run(40_000);
    assert(r.host.has("say -1000433") && r.host.has("despawn"));

    // Simone: shows herself, and a second player brings The Cleaner.
    auto s = Driven!self("npc_simone_the_inconspicuous", simoneInconspicuous);
    s.host.quests[questStaveOfTheAncients] = QuestProgress.incomplete;
    s.host.nearby[precious] = creatureRef(precious);
    s.raise(Spawned());
    assert(s.raise(GossipHello(hero)));
    s.raise(GossipSelect(hero, 0, 0, SimoneTheInconspicuous.showFace));
    s.run(10_000);
    assert(s.host.has("summon 14538") && s.host.has("summon 14533") && s.host.has("despawn 14528"));
    auto d = Driven!self("npc_simone_seductress", simoneSeductress);
    d.raise(EnteredCombat(hero));
    d.raise(Damaged(EntityRef(9), 10, 100, 98));
    assert(d.host.has("summon 14503") && d.host.has("despawn"));
}
