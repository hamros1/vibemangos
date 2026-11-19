/**
 * Burning Steppes: Grark Lorkrub, whom the player on "A Precarious Predicament" (4121) captures and
 * walks to Lexlort's execution; and Franklin the Friendly, who shows the hunter on "Stave of the
 * Ancients" (7636) his true face, Klinfran the Crazed.
 */
module dmangos.scripts.burningsteppes;

import dmangos.script;

/**
 * Grark Lorkrub: shackled (Capture Grark), he cannot die; below a quarter of his health he submits
 * and gives the quest. Taken on it, he walks to Lexlort (`script_waypoint`, points counted from 1),
 * stopping for three ambushes until each is beaten (four Blackrock, then four with Flamescale
 * Dragonspawn, then three Searscale Drakes), and at the end High Executioner Nuzark and the Shadow
 * of Lexlort come: after their talk Nuzark's axe falls, the quest's event happens and Grark dies.
 */
@creature("npc_grark_lorkrub")
struct GrarkLorkrub
{
    enum uint questPrecariousPredicament = 4121, spellCaptureGrark = 14250;
    enum uint ambusher = 9522, raider = 9605, dragonspawn = 7042, drake = 7046, nuzark = 9538, lexlort = 9539;
    enum uint factionFriendly = 29, npcFlagQuestGiver = 2, uninteractible = 0x0200_0000;
    /// `script_texts` rows.
    enum : int
    {
        sayStart = -1000873, sayPay = -1000874, sayFirstAmbushStart = -1000875, sayFirstAmbushEnd = -1000876,
        saySecondAmbushStart = -1000877, saySecondAmbushEnd = -1000878, sayThirdAmbushStart = -1000879,
        sayThirdAmbushEnd = -1000880, emoteLaugh = -1000881, sayLastStand = -1000882, sayLexlort1 = -1000883,
        sayLexlort2 = -1000884, emoteRaiseAxe = -1000885, emoteLowerHand = -1000886, sayLexlort3 = -1000887,
        sayLexlort4 = -1000888, emoteSubmit = -1000889, sayAggro = -1000890,
    }
    enum uint emoteAttackTwoHanded = 38;

    /// The scene at the end, a line at a time.
    enum Step : ubyte { lexlort1, lexlort2, raiseAxe, lowerHand, lexlort3, axe, lexlort4 }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 5000 };
    bool shackled, submitted;
    ubyte killed;           /// ambushers dead
    EntityRef[3] drakes;
    EntityRef nuzarkRef, lexlortRef;

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == spellCaptureGrark && !submitted)
        {
            shackled = true;
            me.deathPrevention(true);
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!shackled || submitted || e.after > 25)
            return;
        submitted = true;
        me.say(emoteSubmit);
        me.setFaction(factionFriendly);
        me.evade();
        me.deathPrevention(false);
        me.npcFlags(npcFlagQuestGiver);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!escort.active)
            me.say(sayAggro);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questPrecariousPredicament || escort.active)
            return;
        killed = 0;
        drakes[] = EntityRef.init;
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case 1:
            me.say(sayStart);
            break;
        case 7:
            me.say(sayPay);
            break;
        case 12:
            me.say(sayFirstAmbushStart);
            escort.paused = true;
            ambush(me, ambusher, Location(-7844.3f, -1521.6f, 139.2f, 0.0f));
            ambush(me, ambusher, Location(-7860.4f, -1507.8f, 141.0f, 6.0f));
            ambush(me, raider, Location(-7845.6f, -1508.1f, 138.8f, 6.1f));
            ambush(me, raider, Location(-7859.8f, -1521.8f, 139.2f, 6.2f));
            break;
        case 24:
            me.say(saySecondAmbushStart);
            escort.paused = true;
            ambush(me, ambusher, Location(-8035.3f, -1222.2f, 135.5f, 5.1f));
            ambush(me, dragonspawn, Location(-8037.5f, -1216.9f, 135.8f, 5.1f));
            ambush(me, ambusher, Location(-8009.5f, -1222.1f, 139.2f, 3.9f));
            ambush(me, dragonspawn, Location(-8007.1f, -1219.4f, 140.1f, 3.9f));
            break;
        case 28:
            static immutable Location[3] drakesAt = [Location(-7897.8f, -1123.1f, 233.4f, 3.0f),
                Location(-7898.8f, -1125.1f, 193.9f, 3.0f), Location(-7895.6f, -1119.5f, 194.5f, 3.1f)];
            foreach (i, at; drakesAt)
                drakes[i] = me.summon(drake, at, 60_000);
            break;
        case 30:
            escort.paused = true;
            me.say(sayThirdAmbushStart);
            foreach (d; drakes)
                if (d)
                    me.attack(d, escort.player);
            break;
        case 36:
            me.say(emoteLaugh);
            break;
        case 45:
            escort.paused = true;
            me.say(sayLastStand);
            nuzarkRef = me.summon(nuzark, Location(-7532.3f, -1029.4f, 258.0f, 2.7f), 40_000);
            lexlortRef = me.summon(lexlort, Location(-7532.8f, -1032.9f, 258.2f, 2.5f), 40_000);
            steps.after(Step.lexlort1, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.summoned.entry == nuzark || e.summoned.entry == lexlort)
            return;
        switch (++killed)
        {
        case 4:
            me.say(sayFirstAmbushEnd);
            escort.paused = false;
            break;
        case 8:
            me.say(saySecondAmbushEnd);
            escort.paused = false;
            break;
        case 11:
            me.say(sayThirdAmbushEnd);
            escort.paused = false;
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.lexlort1:
            me.sayOther(lexlortRef, sayLexlort1);
            me.standState(StandState.kneel);
            steps.after(Step.lexlort2, 3.seconds);
            break;
        case Step.lexlort2:
            me.sayOther(lexlortRef, sayLexlort2);
            steps.after(Step.raiseAxe, 5.seconds);
            break;
        case Step.raiseAxe:
            me.sayOther(nuzarkRef, emoteRaiseAxe);
            steps.after(Step.lowerHand, 4.seconds);
            break;
        case Step.lowerHand:
            me.sayOther(lexlortRef, emoteLowerHand);
            steps.after(Step.lexlort3, 3.seconds);
            break;
        case Step.lexlort3:
            me.sayOther(lexlortRef, sayLexlort3);
            steps.after(Step.axe, 3.seconds);
            break;
        case Step.axe:
            // The axe falls: he lies as if dead until the scene is over.
            me.unitFlags(uninteractible);
            me.standState(StandState.dead);
            steps.after(Step.lexlort4, 5.seconds);
            break;
        case Step.lexlort4:
            me.sayOther(lexlortRef, sayLexlort4);
            me.questEvent(escort.player, escort.quest);
            escort.active = false;
            me.die();
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.fail(me);
    }

    /// One of the ambush, at `at`, for the player.
    private void ambush(ref CreatureContext me, uint entry, Location at)
    {
        me.summon(entry, at, 20_000, escort.player);
    }
}

/**
 * Franklin the Friendly, and what he becomes, Klinfran the Crazed: the hunter on the quest asks him
 * to show his real face; he stops, points, and turns into the demon, whom only that hunter may
 * fight. Anybody else joining in, Klinfran goes and The Cleaner comes for them. Scorpid Sting takes
 * his Demonic Frenzy away. Left alone for twenty minutes, he goes.
 */
@creature("npc_klinfran")
struct Klinfran
{
    enum uint questStaveOfTheAncients = 7636, franklin = 14529, klinfranTheCrazed = 14534, theCleaner = 14503;
    enum uint spellDemonicFrenzy = 23257, spellEntropicSting = 23260, spellScorpidSting4 = 14277;
    enum int emoteFrenzy = -1000001;
    enum uint emotePoint = 25, actionShowFace = 1;

    enum Step : ubyte { point, transform, frenzy, leave }
    Schedule!Step steps;
    EntityRef hunter;
    bool transformed;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (transformed || me.questStatus(e.player, questStaveOfTheAncients) != QuestProgress.incomplete)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Show me your real face, demon.", actionShowFace);
        me.sendGossip(e.player, 0, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != actionShowFace || transformed || steps.pending(Step.transform))
            return;
        me.closeGossip(e.player);
        hunter = e.player;
        me.npcFlags(0);
        steps.after(Step.point, 5.seconds);
        steps.after(Step.transform, 10.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!transformed)
            return;
        if (hunter && e.enemy != hunter)
            return leave(me, e.enemy);
        hunter = e.enemy;
        steps.after(Step.frenzy, 5.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (transformed && hunter && e.attacker != hunter)
            leave(me, e.attacker);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellScorpidSting4 || !transformed)
            return;
        me.removeAura(me.self, spellDemonicFrenzy);
        me.castSelf(spellEntropicSting, true);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.point:
            me.emote(emotePoint);
            break;
        case Step.transform:
            if (me.changeEntry(klinfranTheCrazed))
            {
                transformed = true;
                steps.after(Step.leave, (20 * 60).seconds);
            }
            break;
        case Step.frenzy:
            if (!me.inCombat)
                break;
            if (me.castSelf(spellDemonicFrenzy) == ActionResult.ok)
            {
                me.say(emoteFrenzy);
                steps.after(Step.frenzy, 15.seconds);
            }
            else
                steps.after(Step.frenzy, 1.seconds);
            break;
        case Step.leave:
            if (me.inCombat)
                steps.after(Step.leave, 10.seconds);
            else
                me.despawn();
            break;
        }
    }

    /// Someone else joined in: he goes, and The Cleaner comes for them.
    private void leave(ref CreatureContext me, EntityRef intruder)
    {
        me.summon(theCleaner, me.location, 20 * 60_000, intruder);
        steps.clear();
        me.despawn();
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.burningsteppes;
    auto g = Driven!zone.make("npc_grark_lorkrub");
    g.raise(SpellHit(g.host.player, 14250));
    assert(g.host.did("death prevention true"));
    g.raise(Damaged(g.host.player, 10, 30, 20));
    assert(g.host.did("say -1000889") && g.host.faction == 29 && g.host.did("evade") && g.host.did("npc flags 2"));
    g.host.pathLength = 45;
    g.raise(QuestAccepted(g.host.player, 4121));
    g.walk();
    assert(g.host.did("say -1000875") && g.host.summons == 4, "the first ambush");
    foreach (i; 0 .. 4)
        g.raise(SummonedDied(creatureRef(9522, i)));
    assert(g.host.did("say -1000876"));
    g.tick(100);
    g.walk();
    foreach (i; 0 .. 4)
        g.raise(SummonedDied(creatureRef(9522, i)));
    g.tick(100);
    g.walk();
    assert(g.host.did("say -1000879") && g.host.did("attack 7046 0"));
    foreach (i; 0 .. 3)
        g.raise(SummonedDied(creatureRef(7046, i)));
    g.tick(100);
    g.walk();
    assert(g.host.did("say -1000882") && g.host.did("summon 9539"));
    g.tick(30_000);
    assert(g.host.did("say of 9539 -1000888") && g.host.did("event 4121") && g.host.did("die"));
    assert(!g.host.did("fail 4121"));

    auto k = Driven!zone.make("npc_klinfran");
    k.raise(GossipHello(k.host.player));
    assert(k.host.did("gossip 0 1"));
    k.raise(GossipSelect(k.host.player, 0, 0, 1));
    k.tick(10_000);
    assert(k.host.did("emote 25") && k.host.did("entry 14534"));
    k.host.fighting = true;
    k.raise(EnteredCombat(k.host.player));
    k.tick(5000);
    assert(k.host.did("cast 23257") && k.host.did("say -1000001"));
    k.raise(Damaged(EntityRef(8), 10, 90, 80));
    assert(k.host.did("summon 14503") && k.host.did("despawn"));
}
