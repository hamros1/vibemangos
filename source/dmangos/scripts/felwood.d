/**
 * Felwood: the kitten that a moonwell's water turns into a corrupted saber, released to Winna
 * ("Corrupted Saber", 4506); the escorts of Captured Arko'narin out of Jaedenar ("Rescue From
 * Jaedenar", 5203) and of Arei, the ancient spirit ("Ancient Spirit", 4261).
 */
module dmangos.scripts.felwood;

import dmangos.script;

/**
 * The kitten, and the corrupted saber it becomes: summoned by its player at the moonwell, it jumps
 * in, turns into a saber after a while, and follows the player; next to Winna, the player releases
 * it to her (the quest's event).
 */
@creature("npc_kitten", "npc_corrupt_saber")
struct Kitten
{
    enum uint questCorruptSaber = 4506, winna = 9996, corruptSaber = 10042, spellSaberVisual = 16510, gossipFlag = 1,
        release = 1;
    enum : int { emoteJump = -1000541, emoteFollow = -1000542 }

    enum Step : ubyte { turn, look }
    Schedule!Step steps;
    Follower follower;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        const player = me.owner;
        if (!player.isPlayer || me.self.entry == corruptSaber)
            return;
        follower.start(me, player, 0);
        follower.pause(me, true);
        me.say(emoteJump);
        me.unitFlags(UnitFlag.notAttackable);
        steps.after(Step.turn, 7500.msecs);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.turn:
            me.castSelf(spellSaberVisual);
            me.changeEntry(corruptSaber);
            me.say(emoteFollow, follower.player);
            follower.pause(me, false);
            break;
        case Step.look:
            if (!follower.active)
                return steps.cancel(Step.look);
            if (me.self.entry == corruptSaber || me.entryOf(me.self) == corruptSaber)
                if (me.creatureNearby(winna, 5))
                {
                    me.npcFlags(gossipFlag);
                    steps.cancel(Step.look);
                }
            break;
        }
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questCorruptSaber) != QuestProgress.incomplete || !me.creatureNearby(winna, 5))
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "I want to release the corrupted saber to Winna.", release);
        me.sendGossip(e.player, 0, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != release)
            return;
        me.closeGossip(e.player);
        follower.complete(me);
        me.questEvent(e.player, questCorruptSaber);
    }
}

/**
 * Captured Arko'narin: out of her cage in Jaedenar and through it (`waypoint_path` 11016, whose
 * points' scripts tell much of the tale: her armour, Trey's spirit); Trey's spirit beaten, on to the
 * end of the road, where she thanks the player (the quest's event).
 */
@creature("npc_captured_arkonarin")
struct CapturedArkonarin
{
    enum uint questRescueJaedenar = 5203, spiritTrey = 11141, cage = 176306, sayEscortStart = 6433;
    enum : uint { spellMortalStrike = 16856, spellCleave = 15496 }
    private static immutable uint[3] aggroLines = [6801, 6802, 6803];

    enum Step : ubyte { mortalStrike, cleave }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000, runScripts: true };
    bool canAttack;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.kneel);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questRescueJaedenar || escort.active)
            return;
        me.standState(StandState.stand);
        me.setFaction(EscortFaction.neutralNeutralActive);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        canAttack = false;
        escort.start(me, e.player, e.quest);
        if (const c = me.objectNearby(cage, 5))
            me.useObject(c);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (me.random(10) < 8)
            me.sayText(aggroLines[me.random(3)], e.enemy);
        if (canAttack)
        {
            steps.after(Step.mortalStrike, (5 + me.random(3)).seconds);
            steps.after(Step.cleave, (1 + me.random(4)).seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return steps.clear();
        final switch (step)
        {
        case Step.mortalStrike:
            if (me.castSpell(spellMortalStrike) == ActionResult.ok)
                steps.after(Step.mortalStrike, (7 + me.random(4)).seconds);
            else
                steps.after(Step.mortalStrike, 1.seconds);
            break;
        case Step.cleave:
            if (me.castSpell(spellCleave) == ActionResult.ok)
                steps.after(Step.cleave, (3 + me.random(4)).seconds);
            else
                steps.after(Step.cleave, 1.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 1:
            me.sayText(sayEscortStart, escort.player);
            me.emote(1);
            break;
        case 37:
            canAttack = true;
            break;
        case 83:
            escort.paused = true; // until Trey's spirit is beaten
            break;
        case 85:
            me.face(escort.player);
            me.groupQuestEvent(escort.player, questRescueJaedenar);
            me.unitFlags(UnitFlag.immuneToNpc);
            escort.quest = 0; // done: nothing to fail any more
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        if (e.summoned.entry == spiritTrey)
            escort.paused = false;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }
}

/**
 * Arei: the ancient spirit led out of the Irontree Woods; at the woods' edge the Irontree come for
 * her, and with them dead she lifts her curse, turns into a sapling's spirit, and thanks the player.
 */
@creature("npc_arei")
struct Arei
{
    enum uint questAncientSpirit = 4261, toxicHorror = 7132, irontreeWanderer = 7138, irontreeStomper = 7139;
    enum : uint { spellWitherStrike = 5337, spellAreiTransform = 14888 }
    enum : int
    {
        sayEscortStart = -1001159, sayAttackIrontree = -1001160, sayAttackToxicHorror = -1001161, sayExitWoods = -1001162,
        sayClearPath = -1001163, sayAshenvale = -1001164, sayTransform = -1001165, sayLiftCurse = -1001166,
        sayEscortComplete = -1001167,
    }

    enum Step : ubyte { witherStrike, ashenvale, transform, liftCurse, complete }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    bool aggroIrontree, aggroHorror;
    ubyte irontreeLeft;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questAncientSpirit || escort.active)
            return;
        me.say(sayEscortStart, e.player);
        me.setFaction(EscortFaction.neutralNeutralPassive);
        aggroIrontree = aggroHorror = false;
        irontreeLeft = 0;
        escort.start(me, e.player, e.quest, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const entry = e.enemy.entry;
        if ((entry == irontreeWanderer || entry == irontreeStomper) && !aggroIrontree)
        {
            me.say(sayAttackIrontree);
            aggroIrontree = true;
        }
        else if (entry == toxicHorror && !aggroHorror)
        {
            me.say(sayAttackToxicHorror, escort.player);
            aggroHorror = true;
        }
        steps.after(Step.witherStrike, (1 + me.random(4)).seconds);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (escort.reached(me, e) + 1 != 37)
            return;
        escort.paused = true;
        const stomper = me.summon(irontreeStomper, Location(6573.321f, -1195.213f, 442.489f), 60_000);
        me.say(sayExitWoods, stomper);
        foreach (summoned; [stomper, me.summon(irontreeWanderer, Location(6573.240f, -1213.475f, 443.643f), 60_000),
                me.summon(irontreeWanderer, Location(6583.354f, -1209.811f, 444.769f), 60_000)])
            if (summoned && me.attack(summoned, me.self) == ActionResult.ok)
                ++irontreeLeft;
        if (!irontreeLeft)
            steps.after(Step.ashenvale, 4.seconds);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        if ((e.summoned.entry == irontreeStomper || e.summoned.entry == irontreeWanderer) && irontreeLeft && --irontreeLeft == 0)
        {
            me.say(sayClearPath);
            steps.after(Step.ashenvale, 4.seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.witherStrike:
            if (me.inCombat)
                steps.after(Step.witherStrike, me.castSpell(spellWitherStrike) == ActionResult.ok
                    ? (3 + me.random(4)).seconds : 1.seconds);
            break;
        case Step.ashenvale:
            me.say(sayAshenvale, escort.player);
            steps.after(Step.transform, 5.seconds);
            break;
        case Step.transform:
            me.say(sayTransform);
            steps.after(Step.liftCurse, 3.seconds);
            break;
        case Step.liftCurse:
            me.castSelf(spellAreiTransform);
            me.say(sayLiftCurse, escort.player);
            steps.after(Step.complete, 7.seconds);
            break;
        case Step.complete:
            me.say(sayEscortComplete, escort.player);
            me.groupQuestEvent(escort.player, questAncientSpirit);
            escort.active = false;
            me.despawn(10_000);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.felwood;

    // The kitten: in the moonwell, a saber, and released to Winna.
    auto k = Driven!self("npc_kitten", 9937);
    k.host.owner_ = hero;
    k.host.quests[Kitten.questCorruptSaber] = QuestProgress.incomplete;
    k.raise(Spawned());
    assert(k.host.has("say -1000541") && k.host.has("unfollow"));
    k.run(7500);
    assert(k.host.has("entry 10042") && k.host.has("say -1000542"));
    assert(!k.raise(GossipHello(hero)), "not near Winna");
    k.host.nearby[Kitten.winna] = creatureRef(Kitten.winna);
    assert(k.raise(GossipHello(hero)));
    k.raise(GossipSelect(hero, 0, 0, Kitten.release));
    assert(k.host.has("event 4506") && k.host.has("despawn"));

    // Arko'narin: her path's scripts run as she reaches its points; Trey's spirit holds her up.
    auto a = Driven!self("npc_captured_arkonarin", 11_016, 88);
    a.host.path[15].scriptId = 1_101_601;
    a.raise(QuestAccepted(hero, CapturedArkonarin.questRescueJaedenar));
    a.walkTo(82);
    assert(a.host.has("script 1101601") && a.host.has("text 6433"));
    a.run(500);
    assert(!a.host.has("move 83"), "held until the spirit is beaten");
    a.raise(SummonedDied(creatureRef(CapturedArkonarin.spiritTrey), hero));
    a.run(100);
    a.walkTo(84);
    assert(a.host.has("event 5203"));

    // Arei: the Irontree at the woods' edge, then the curse lifted.
    auto r = Driven!self("npc_arei", 9598, 40);
    r.raise(QuestAccepted(hero, Arei.questAncientSpirit));
    r.walkTo(36);
    assert(r.host.summons == 3);
    foreach (c; r.host.summoned)
        r.raise(SummonedDied(c, hero));
    r.run(20_000);
    assert(r.host.has("say -1001163") && r.host.has("cast 14888") && r.host.has("event 4261"));
}
