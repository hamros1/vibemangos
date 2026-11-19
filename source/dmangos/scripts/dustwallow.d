/**
 * Dustwallow Marsh: Mor'okk's challenge ("Challenge to Mor'okk", 1173); Ogron's questioning of
 * Reethe, with Caldwell's ambush ("Questioning Reethe", 1273); Private Hendel's surrender ("The
 * Missing Diplomat", 1324) and Tervosh at Sentry Point (1265); and Stinky Ignatz's escape (1222,
 * 1270).
 */
module dmangos.scripts.dustwallow;

import dmangos.script;

/**
 * Mor'okk: walks off to his challenge spot; there he fights the player who challenged him, and at
 * a third of his health he gives up (the quest's event) and runs. Beaten the other way, or left, the
 * challenge fails.
 */
@creature("npc_morokk")
struct Morokk
{
    enum uint questChallengeMorokk = 1173;
    enum : uint { factionHostile = 168, factionRunning = 35, factionSpawn = 29 }
    enum : int { sayChallenge = -1000499, sayScared = -1000500 }

    Escort escort = { despawnAfterMs: 1000 };
    bool success, challenged;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.setFaction(factionSpawn);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questChallengeMorokk || escort.active)
            return;
        success = challenged = false;
        escort.start(me, e.player, e.quest, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (escort.reached(me, e) != 0)
            return;
        escort.pause(true);
        if (me.alive(escort.player) && me.distanceTo(escort.player) <= 70)
        {
            challenged = true;
            me.say(sayChallenge, escort.player);
            me.unitFlags(UnitFlag.immuneToPlayer, false);
            me.passive(false);
            me.setFaction(factionHostile);
            me.preventDeath(true);
            me.attack(escort.player);
        }
        else
            escort.pause(false);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!challenged || success || e.after > 30)
            return;
        success = true;
        me.groupQuestEvent(escort.player, questChallengeMorokk);
        me.setFaction(factionRunning);
        me.unitFlags(UnitFlag.immuneToPlayer);
        me.passive(true);
        me.preventDeath(false);
        me.say(sayScared);
        escort.pause(false);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        // Home from the fight without having given up: the challenge is lost.
        if (escort.active && challenged && !success)
            escort.fail(me);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Ogron: leads the player to Reethe and questions him; Caldwell, Hallan and two skirmishers come to
 * silence Reethe and turn on Ogron. Ogron alive after the fight, the questioning is done.
 */
@creature("npc_ogron")
struct Ogron
{
    enum uint questQuestioning = 1273;
    enum : uint { reethe = 4980, caldwell = 5046, hallan = 5045, skirmisher = 5044, spellFakeShot = 7105,
        factionFriendly = 35, factionTheramoreHostile = 151 }
    enum : int
    {
        sayStart = -1000452, saySpot = -1000453, sayRetWhat = -1000454, sayRetSwear = -1000455, sayReplyRet = -1000456,
        sayRetTaken = -1000457, sayTellFire = -1000458, sayRetNoCloser = -1000459, sayRetNoFire = -1000460,
        sayRetHear = -1000461, sayCalFound = -1000462, sayCalMercy = -1000463, sayHallGlad = -1000464,
        emoteRetArrow = -1000465, sayRetArrow = -1000466, sayCalCleanup = -1000467, sayNoDie = -1000468,
        saySurvive = -1000469, sayRetLucky = -1000470, sayThanks = -1000471,
    }
    enum Phase : ubyte { intro, guests, fight, complete }

    private static immutable spawnAt = Location(-3383.501953f, -3203.383301f, 36.149f);
    private static immutable meetAt = Location(-3371.414795f, -3212.179932f, 34.210f);

    enum Step : ubyte { talk }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    Phase phase;
    ubyte counter, guestsAlive;
    EntityRef reetheRef;
    EntityRef[4] guests; // Caldwell, Hallan, two skirmishers

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questQuestioning || escort.active)
            return;
        phase = Phase.intro;
        counter = guestsAlive = 0;
        escort.start(me, e.player, e.quest);
        me.setFaction(EscortFaction.neutralFriendPassive);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        me.say(sayStart, e.player);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 10:
            me.say(saySpot);
            break;
        case 11:
            reetheRef = me.creatureNearby(reethe, 40);
            me.sayFrom(reetheRef, sayRetWhat);
            break;
        case 12:
            escort.pause(true);
            steps.every(Step.talk, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat || phase == Phase.fight)
            return;
        switch (counter)
        {
        case 0: me.sayFrom(reetheRef, sayRetSwear); break;
        case 1: me.say(sayReplyRet); break;
        case 2: me.sayFrom(reetheRef, sayRetTaken); break;
        case 3:
            me.say(sayTellFire);
            me.sayFrom(reetheRef, sayRetNoCloser);
            break;
        case 4: me.sayFrom(reetheRef, sayRetNoFire); break;
        case 5:
            me.sayFrom(reetheRef, sayRetHear);
            foreach (i, entry; [caldwell, hallan, skirmisher, skirmisher])
            {
                guests[i] = me.summon(entry, spawnAt, 300_000);
                me.setFactionOf(guests[i], factionFriendly);
                me.moveOther(guests[i], Location(meetAt.x + i, meetAt.y + (i & 1), meetAt.z));
            }
            phase = Phase.guests;
            break;
        case 6: me.sayFrom(guests[0], sayCalFound); break;
        case 7: me.sayFrom(guests[0], sayCalMercy); break;
        case 8:
            me.sayFrom(guests[1], sayHallGlad);
            me.castAs(guests[1], spellFakeShot, reetheRef);
            break;
        case 9:
            me.sayFrom(reetheRef, emoteRetArrow);
            me.sayFrom(reetheRef, sayRetArrow);
            break;
        case 10:
            me.sayFrom(guests[0], sayCalCleanup);
            me.say(sayNoDie);
            break;
        case 11:
            foreach (guest; guests)
                if (guest && me.alive(guest))
                {
                    me.setFactionOf(guest, factionTheramoreHostile);
                    if (me.attackBy(guest, me.self) == ActionResult.ok)
                        ++guestsAlive;
                }
            phase = guestsAlive ? Phase.fight : Phase.complete;
            break;
        case 12:
            me.groupQuestEvent(escort.player, questQuestioning);
            me.say(saySurvive);
            break;
        case 13: me.sayFrom(reetheRef, sayRetLucky); break;
        case 14:
            me.say(sayThanks);
            escort.run = true;
            escort.pause(false);
            steps.cancel(Step.talk);
            break;
        default:
            break;
        }
        if (phase != Phase.fight)
            ++counter;
    }

    void on(ref CreatureContext me, const ref SummonDied e)
    {
        if (phase == Phase.fight && guestsAlive && --guestsAlive == 0)
        {
            phase = Phase.complete;
            ++counter;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (phase == Phase.fight && escort.active)
        {
            phase = Phase.complete; // the fight is over and he stands
            ++counter;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }
}

/**
 * Private Hendel: the player on "The Missing Diplomat" fights him and his sentries; below a fifth of
 * his health he surrenders, the sentries flee, and Jaina Proudmoore comes with Archmage Tervosh and
 * Pained; Tervosh's teleport of Hendel is the quest's event.
 */
@creature("npc_private_hendel")
struct PrivateHendel
{
    enum uint questMissingDiplo16 = 1324, factionHostile = 168;
    enum : uint { sentry = 5184, jaina = 4968, tervosh = 4967, pained = 4965, spellTeleportVisual = 12980, spellTeleport = 7079 }
    enum int emoteSurrender = -1000415;

    private static immutable uint[3] outroEntries = [tervosh, jaina, pained];
    private static immutable Location[3] outroAt = [Location(-2857.604492f, -3354.784912f, 35.369640f, 3.16604f),
        Location(-2858.120117f, -3358.469971f, 36.086300f, 3.16604f), Location(-2857.379883f, -3351.370117f, 34.178001f, 3.16604f)];
    private static immutable Location[3] outroTo = [Location(-2881.546631f, -3346.477539f, 34.143719f),
        Location(-2879.697998f, -3347.789063f, 34.772892f), Location(-2879.959961f, -3344.469971f, 34.670502f)];
    private static immutable sentryFlee = Location(-2917.56f, -3329.90f, 30.37f);

    enum Step : ubyte { teleport }
    Schedule!Step steps;
    EntityRef player;
    bool surrendered;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questMissingDiplo16 || surrendered)
            return;
        player = e.player;
        me.setFaction(factionHostile);
        me.preventDeath(true);
        me.attack(e.player);
        EntityRef[4] sentries;
        foreach (s; sentries[0 .. me.creaturesNearby(sentry, 40, sentries[])])
        {
            me.setFactionOf(s, factionHostile);
            me.attackBy(s, e.player);
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (surrendered || player == EntityRef.init || e.after >= 20)
            return;
        surrendered = true;
        me.say(emoteSurrender);
        me.passive(true); // the fight stops
        EntityRef[4] sentries;
        foreach (s; sentries[0 .. me.creaturesNearby(sentry, 40, sentries[])])
        {
            me.setFactionOf(s, 0);
            me.moveOther(s, sentryFlee, 0, true);
            me.despawn(s, 4000);
        }
        foreach (i, entry; outroEntries)
        {
            const who = me.summon(entry, outroAt[i], 180_000);
            me.castAs(who, spellTeleportVisual, who);
            me.moveOther(who, outroTo[i]);
        }
        steps.after(Step.teleport, 15.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        // Tervosh sends him off.
        if (const t = me.creatureNearby(tervosh, 60))
            me.castAs(t, spellTeleport, me.self, true);
        if (me.questStatus(player, questMissingDiplo16) == QuestProgress.incomplete)
            me.groupQuestEvent(player, questMissingDiplo16);
        me.despawn(2000);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!surrendered)
        {
            me.restoreFaction();
            me.preventDeath(false);
            player = EntityRef.init;
        }
    }
}

/// Stinky Ignatz: led through the marsh to gather a Bogbean, then home.
@creature("npc_stinky_ignatz")
struct StinkyIgnatz
{
    enum uint questAlliance = 1222, questHorde = 1270, bogbeanPlant = 20939, emoteStateUseStanding = 69;
    enum : int
    {
        sayBegin = -1000958, sayFirstStop = -1000959, saySecondStop = -1001141, sayThirdStop1 = -1001142,
        sayThirdStop2 = -1001143, sayThirdStop3 = -1001144, sayPlantGathered = -1001145, sayEnd = -1000962,
        sayEndEmote = -1010032, sayAggro1 = -1000960, sayAggro2 = -1000961, sayAggro3 = -1001146, sayAggro4 = -1001147,
    }

    Escort escort = { despawnAfterMs: 1000 };
    EntityRef plant;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if ((e.quest != questAlliance && e.quest != questHorde) || escort.active)
            return;
        me.say(sayBegin);
        escort.start(me, e.player, e.quest);
        me.setFaction(EscortFaction.neutralNeutralPassive);
        me.standState(StandState.stand);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        static immutable int[4] lines = [sayAggro1, sayAggro2, sayAggro3, sayAggro4];
        const i = me.random(4);
        me.say(lines[i], i == 3 ? e.enemy : EntityRef.init);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 6: me.say(sayFirstStop); break;
        case 11: me.say(saySecondStop); break;
        case 25: me.say(sayThirdStop1); break;
        case 26:
            me.say(sayThirdStop2);
            plant = me.objectNearby(bogbeanPlant, 100);
            if (plant)
                me.face(plant);
            break;
        case 27: me.say(sayThirdStop3, escort.player); break;
        case 30: me.emoteState(emoteStateUseStanding); break;
        case 31:
            if (plant)
                me.useObject(plant);
            plant = EntityRef.init;
            me.emoteState(0);
            me.say(sayPlantGathered);
            break;
        case 40:
            me.groupQuestEvent(escort.player, escort.quest);
            me.say(sayEnd, escort.player);
            break;
        case 41: me.say(sayEndEmote); break;
        default: break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/// Sentry Point: a player on "The Missing Diplomat" (part 14) finds Archmage Tervosh arriving there.
@areaTrigger("at_sentry_point")
struct AtSentryPoint
{
    enum uint questMissingDiplo14 = 1265, tervosh = 4967, spellTeleportVisual = 799;

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        const status = at.questStatus(e.player, questMissingDiplo14);
        if (status == QuestProgress.none || status == QuestProgress.complete || status == QuestProgress.rewarded)
            return;
        at.consume();
        if (at.creatureNear(tervosh, e.at, 100))
            return;
        if (const t = at.summon(tervosh, Location(-3476.51f, -4105.94f, 17.1f, 5.3816f), 60_000))
            at.castSpell(t, spellTeleportVisual, t);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.dustwallow;

    // Mor'okk: the challenge at his spot; beaten to a third, he gives up.
    auto m = Driven!self("npc_morokk", 4500, 8);
    m.raise(QuestAccepted(hero, Morokk.questChallengeMorokk));
    m.walkTo(0);
    assert(m.host.has("faction 168") && m.host.has("attack 4500 hero"));
    m.raise(Damaged(hero, 100, 50, 40));
    assert(!m.host.has("event 1173"));
    m.raise(Damaged(hero, 100, 40, 25));
    assert(m.host.has("event 1173") && m.host.has("say -1000500") && m.host.has("faction 35"));

    // Ogron: the questioning, the ambush, and his survival.
    auto o = Driven!self("npc_ogron", 4983, 23);
    o.host.nearby[Ogron.reethe] = creatureRef(Ogron.reethe);
    o.raise(QuestAccepted(hero, Ogron.questQuestioning));
    o.walkTo(11);
    o.run(30_000);
    assert(o.host.summons == 4 && o.host.has("say as 4980 -1000461"));
    o.run(30_000);
    assert(o.host.has("attack 5046 4983") && !o.host.has("event 1273"));
    foreach (c; o.host.summoned)
        o.raise(SummonDied(c, hero));
    o.run(15_000);
    assert(o.host.has("event 1273") && o.host.has("say -1000471"));

    // Hendel: his surrender, Tervosh, the quest.
    auto h = Driven!self("npc_private_hendel", 4966);
    h.host.nearby[PrivateHendel.sentry] = creatureRef(PrivateHendel.sentry);
    h.host.quests[PrivateHendel.questMissingDiplo16] = QuestProgress.incomplete;
    h.raise(QuestAccepted(hero, PrivateHendel.questMissingDiplo16));
    assert(h.host.has("attack 4966 hero") && h.host.has("attack 5184 hero") && h.host.has("immortal"));
    h.raise(Damaged(hero, 100, 30, 15));
    assert(h.host.has("say -1000415") && h.host.summons == 3);
    h.run(15_000);
    assert(h.host.has("event 1324"));
}
