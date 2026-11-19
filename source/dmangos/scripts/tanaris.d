/**
 * Tanaris: Aquementas, whose fight gives the Silver Totem of Aquementas to one who carries what
 * the totem is made of ("Aquementas", 4005); the escort of the homing robot OOX-17/TN ("Rescue
 * OOX-17/TN!", 648); and Tooga the tortoise, led to Torta ("Tooga's Quest", 1560).
 */
module dmangos.scripts.tanaris;

import dmangos.script;

/// Aquementas: friendly for ten seconds after it rises, then an elemental; Frost Shock and Aqua Jet.
@creature("mob_aquementas")
struct Aquementas
{
    enum : uint { spellAquaJet = 13586, spellFrostShock = 15089, factionFriendly = 35, factionElemental = 91 }
    enum : uint { itemSilverTotem = 11522, itemBookAquor = 11169, itemSilveryClaws = 11172, itemIrontreeHeart = 11173 }
    enum int aggroYell = -1000168;

    enum Step : ubyte { turn, frostShock, aquaJet }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        rise(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        rise(me);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(aggroYell, e.enemy);
        const player = e.enemy.isPlayer ? e.enemy : me.owner; // a pet's master is credited too
        if (player.isPlayer && me.itemCount(player, itemBookAquor) >= 1 && me.itemCount(player, itemSilveryClaws) >= 11
            && me.itemCount(player, itemIrontreeHeart) >= 1 && me.itemCount(player, itemSilverTotem) == 0)
            me.giveItem(player, itemSilverTotem);
        steps.after(Step.frostShock, 1.seconds);
        steps.after(Step.aquaJet, 5.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.turn:
            me.setFaction(factionElemental);
            break;
        case Step.frostShock:
            if (me.inCombat)
            {
                me.castSpell(spellFrostShock);
                steps.after(Step.frostShock, 15.seconds);
            }
            break;
        case Step.aquaJet:
            if (me.inCombat)
            {
                me.castSelf(spellAquaJet);
                steps.after(Step.aquaJet, 15.seconds);
            }
            break;
        }
    }

    private void rise(ref CreatureContext me)
    {
        steps.clear();
        me.setFaction(factionFriendly);
        steps.after(Step.turn, 10.seconds);
    }
}

/// OOX-17/TN: switched on, it walks to Steamwheedle Port; scorpions, then Wastewander thieves ambush it.
@creature("npc_oox17tn")
struct Oox17tn
{
    enum uint questRescueOox17tn = 648;
    enum : uint { scorpion = 7803, scofflaw = 7805, shadowMage = 5617 }
    enum : int { sayStart = -1000287, sayAggro1 = -1000288, sayAggro2 = -1000289, sayAmbush = -1000290,
        sayAmbushReply = -1000291, sayEnd = -1000292 }

    Escort escort = { despawnAfterMs: 1000 };
    EntityRef[3] ambush;

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
        if (e.quest != questRescueOox17tn || escort.active)
            return;
        me.say(sayStart);
        me.standState(StandState.stand);
        me.setFaction(EscortFaction.neutralFriendActive);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const line = me.random(10);
        if (line < 2)
            me.say(line ? sayAggro2 : sayAggro1);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 23:
            me.say(sayAmbush);
            ambush[0] = attacker(me, scorpion, Location(-8340.70f, -4448.17f, 9.17f, 3.10f));
            ambush[1] = attacker(me, scorpion, Location(-8343.18f, -4444.35f, 9.44f, 2.35f));
            ambush[2] = attacker(me, scorpion, Location(-8348.70f, -4457.80f, 9.58f, 2.02f));
            break;
        case 29:
            me.say(sayAmbush);
            ambush[0] = attacker(me, scofflaw, Location(-7488.02f, -4786.56f, 10.67f, 3.74f));
            ambush[1] = attacker(me, shadowMage, Location(-7486.41f, -4791.55f, 10.54f, 3.26f));
            ambush[2] = attacker(me, scofflaw, Location(-7488.47f, -4800.77f, 9.77f, 2.50f));
            me.sayFrom(ambush[2], sayAmbushReply);
            break;
        case 35:
            me.say(sayEnd);
            me.groupQuestEvent(escort.player, questRescueOox17tn);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        foreach (a; ambush)
            if (a && me.alive(a))
                me.despawn(a);
        escort.fail(me);
    }

    private static EntityRef attacker(ref CreatureContext me, uint entry, Location at)
    {
        const summoned = me.summon(entry, at, 30_000);
        me.attackBy(summoned, me.self);
        return summoned;
    }
}

/**
 * Tooga: follows the player to Torta, now and then thirsty or worried; with Torta, a little talk,
 * and both go into the water.
 */
@creature("npc_tooga")
struct Tooga
{
    enum uint questTooga = 1560, torta = 6015, pointWater = 1;
    enum : int
    {
        sayThirst = -1000391, sayWorried = -1000392, sayPost1 = -1000393, sayTortPost2 = -1000394, sayPost3 = -1000395,
        sayTortPost4 = -1000396, sayPost5 = -1000397, sayTortPost6 = -1000398,
    }

    enum Step : ubyte { look, talk }
    Schedule!Step steps;
    Follower follower;
    EntityRef tortaRef;
    ubyte phase;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questTooga || follower.active)
            return;
        follower.start(me, e.player, e.quest, EscortFaction.neutralFriendPassive);
        phase = 0;
        steps.every(Step.look, 2500.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.look:
            if (!follower.active)
                return steps.cancel(Step.look);
            if (me.inCombat)
                return;
            if (const t = me.creatureNearby(torta, 5))
            {
                if (me.questStatus(follower.player, questTooga) == QuestProgress.incomplete)
                    me.groupQuestEvent(follower.player, questTooga);
                tortaRef = t;
                follower.complete(me, true);
                steps.cancel(Step.look);
                steps.every(Step.talk, 1.seconds, 5.seconds);
                return;
            }
            const line = me.random(51);
            if (line == 10)
                me.say(sayThirst);
            else if (line == 25)
                me.say(sayWorried);
            break;
        case Step.talk:
            if (!me.alive(tortaRef))
            {
                steps.cancel(Step.talk);
                me.despawn(1000);
                return;
            }
            switch (++phase)
            {
            case 1: me.say(sayPost1); break;
            case 2: me.sayFrom(tortaRef, sayTortPost2); break;
            case 3: me.say(sayPost3); break;
            case 4: me.sayFrom(tortaRef, sayTortPost4); break;
            case 5: me.say(sayPost5); break;
            case 6:
                me.sayFrom(tortaRef, sayTortPost6);
                me.moveTo(Location(-7032.664551f, -4906.199219f, -1.606446f), pointWater);
                steps.cancel(Step.talk);
                break;
            default: break;
            }
            break;
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == pointWater)
            me.despawn(1000);
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
    alias self = dmangos.scripts.tanaris;

    // Aquementas gives the totem to one who carries its parts.
    auto a = Driven!self("mob_aquementas", 9453);
    a.raise(Spawned());
    a.run(10_000);
    assert(a.host.has("faction 91"));
    a.raise(EnteredCombat(hero));
    assert(!a.host.has("give 11522"));
    a.host.items = [Aquementas.itemBookAquor: 1, Aquementas.itemSilveryClaws: 11, Aquementas.itemIrontreeHeart: 1];
    a.raise(EnteredCombat(hero));
    assert(a.host.has("give 11522"));

    auto o = Driven!self("npc_oox17tn", 7784, 35);
    o.raise(QuestAccepted(hero, Oox17tn.questRescueOox17tn));
    o.walkTo(34);
    assert(o.host.summons == 6 && o.host.has("say as 7805 -1000291") && o.host.has("event 648"));

    auto t = Driven!self("npc_tooga", 5955);
    t.host.quests[Tooga.questTooga] = QuestProgress.incomplete;
    t.raise(QuestAccepted(hero, Tooga.questTooga));
    t.host.nearby[Tooga.torta] = creatureRef(Tooga.torta);
    t.run(2500);
    assert(t.host.has("event 1560"));
    t.run(30_000);
    assert(t.host.has("say as 6015 -1000398") && t.host.has("move 1"));
}
