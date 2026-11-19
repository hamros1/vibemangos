/**
 * The Barrens: the escorts of Gilthares Firebough out of the Southsea camp ("Free From the Hold",
 * 898) and of Wizzlecrank's shredder out of the Venture Co. drill ("Miss Diggy", "Ziz's Escape", 863);
 * Taskmaster Fizzule, who surrenders to two flares and a salute ("Ten Bucks", "The Book of Fooleries");
 * Twiggy Flathead's affray at the Crossroads arena (1719); and Regthar Deathgate's counterattack on
 * the Kolkar (4021), which brings out Warlord Krom'zar once twenty Kolkar fall.
 */
module dmangos.scripts.barrens;

import dmangos.script;

/// Gilthares Firebough: led from his cage in the Southsea camp to Ratchet (`script_waypoint` 3465).
@creature("npc_gilthares")
struct Gilthares
{
    enum uint questFreeFromHold = 898;
    enum : int
    {
        sayStart = -1000370, sayAtLast = -1000371, sayProceed = -1000372, sayFreebooters = -1000373,
        sayAggro1 = -1000374, sayAlmost = -1000378, saySweet = -1000379, sayFreed = -1000380,
    }

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questFreeFromHold || escort.active)
            return;
        me.setFaction(EscortFaction.hordeNeutralActive);
        me.standState(StandState.stand);
        me.say(sayStart, e.player);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1) // the path's points, from 1
        {
        case 17: me.say(sayAtLast, escort.player); break;
        case 18: me.say(sayProceed, escort.player); break;
        case 19: me.say(sayFreebooters, escort.player); break;
        case 38: me.say(sayAlmost, escort.player); break;
        case 48: me.say(saySweet, escort.player); break;
        case 54:
            me.say(sayFreed, escort.player);
            me.groupQuestEvent(escort.player, questFreeFromHold);
            break;
        default: break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        // Now and then, at the freebooters who come for him.
        if (escort.active && !e.enemy.isPlayer && me.random(4) == 0)
            me.say(sayAggro1 - cast(int) me.random(4), e.enemy);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        me.standState(StandState.stand);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Taskmaster Fizzule: two flares (Flare Gun) make him stop fighting and stand down, a salute then
 * makes him a quest giver; the Book of Fooleries' folly does it all at once. Two minutes later he is
 * himself again.
 */
@creature("npc_taskmaster_fizzule")
struct TaskmasterFizzule
{
    enum : uint { spellFlare = 10113, spellFolly = 10137, factionFriendly = 35, questGiver = 2 }
    enum uint textEmoteSalute = 78, emoteSalute = 66;

    enum Step : ubyte { reset }
    Schedule!Step steps;
    ubyte flares;

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (!e.caster.isPlayer)
            return;
        if (e.spell == spellFlare && flares < 2)
            advance(me, cast(ubyte)(flares + 1));
        else if (e.spell == spellFolly)
            advance(me, 4);
    }

    void on(ref CreatureContext me, const ref EmoteReceived e)
    {
        if (e.textEmote == textEmoteSalute && flares == 2)
            advance(me, 3);
    }

    void on(ref CreatureContext me, Step step)
    {
        flares = 0;
        me.restoreNpcFlags();
        me.unitFlags(UnitFlag.immuneToPlayer, false);
        me.setFaction(0);
        me.reactState(Reaction.aggressive);
    }

    private void advance(ref CreatureContext me, ubyte to)
    {
        flares = to;
        switch (to)
        {
        case 1:
            steps.after(Step.reset, 120.seconds);
            me.unitFlags(UnitFlag.immuneToPlayer);
            break;
        case 2:
            standDown(me);
            break;
        case 3:
            me.npcFlags(questGiver);
            me.emote(emoteSalute);
            break;
        default:
            steps.after(Step.reset, 120.seconds);
            me.unitFlags(UnitFlag.immuneToPlayer);
            standDown(me);
            me.npcFlags(questGiver);
            me.emote(emoteSalute);
            break;
        }
    }

    private void standDown(ref CreatureContext me)
    {
        me.setFaction(factionFriendly);
        me.reactState(Reaction.passive);
        me.evade(); // the fight is over
    }
}

/// The arena's trigger: a player on "The Affray" walks in, and Twiggy starts the fight.
@areaTrigger("at_twiggy_flathead")
struct AtTwiggyFlathead
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (at.questStatus(e.player, TwiggyFlathead.questAffray) != QuestProgress.incomplete)
            return;
        if (const twiggy = at.creatureNear(TwiggyFlathead.twiggy, e.at, 30))
            at.signal(twiggy, TwiggyFlathead.signalStart);
    }
}

/**
 * Twiggy Flathead: six challengers come into the arena and step up one by one against the player
 * who started the affray, then Big Will; with Big Will dead (the quest's kill) it is over. The player
 * dead or gone, the challengers leave.
 */
@creature("npc_twiggy_flathead")
struct TwiggyFlathead
{
    enum uint questAffray = 1719, twiggy = 6248, bigWill = 6238, challenger = 6240, signalStart = 1;
    enum : int { sayBigWillReady = -1000123, sayBegin = -1000124, sayFray = -1000125, sayDown = -1000126, sayOver = -1000127 }
    enum : uint { factionFriendly = 35, factionWill = 32, factionChallenger = 14 }

    private static immutable Location[6] challengerAt = [
        Location(-1683.0f, -4326.0f, 2.79f, 0.00f), Location(-1682.0f, -4329.0f, 2.79f, 0.00f),
        Location(-1683.0f, -4330.0f, 2.79f, 0.00f), Location(-1680.0f, -4334.0f, 2.79f, 1.49f),
        Location(-1674.0f, -4326.0f, 2.79f, 3.49f), Location(-1677.0f, -4334.0f, 2.79f, 1.66f),
    ];
    private static immutable willSpawn = Location(-1713.79f, -4342.09f, 6.05f, 6.15f);
    private static immutable willArena = Location(-1682.31f, -4329.68f, 2.78f, 0.0f);

    enum Step : ubyte { next }
    Schedule!Step steps;
    bool inProgress;
    ubyte stage, ready;
    EntityRef player, will;
    EntityRef[6] challengers;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != signalStart || inProgress || !e.from.isPlayer)
            return;
        me.say(sayBegin, e.from);
        player = e.from;
        inProgress = true;
        stage = ready = 0;
        steps.after(Step.next, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.alive(player) || me.distanceTo(player) > 100)
            return fail(me);
        switch (stage)
        {
        case 0:
            foreach (i, at; challengerAt)
            {
                challengers[i] = me.summon(challenger, at, 600_000);
                me.setFactionOf(challengers[i], factionFriendly);
            }
            ++stage;
            steps.after(Step.next, 5.seconds);
            break;
        case 1:
            me.say(sayFray);
            const next = challengers[ready++];
            me.setFactionOf(next, factionChallenger);
            me.attack(next, player);
            if (ready == challengers.length)
            {
                ++stage;
                steps.after(Step.next, 5.seconds);
            }
            else
                steps.after(Step.next, 25.seconds);
            break;
        case 2:
            will = me.summon(bigWill, willSpawn, 300_000);
            me.setFactionOf(will, factionFriendly);
            me.moveCreature(will, willArena, 1, true);
            ++stage;
            steps.after(Step.next, 15.seconds);
            break;
        case 3:
            me.setFactionOf(will, factionWill);
            me.sayOther(will, sayBigWillReady, player);
            ++stage;
            steps.after(Step.next, 5.seconds);
            break;
        default:
            steps.after(Step.next, 5.seconds); // the fight goes on: the player watched
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        if (!inProgress)
            return;
        if (e.summoned == will)
        {
            me.say(sayOver);
            reset();
        }
        else
        {
            me.say(sayDown);
            if (stage == 1)
                steps.after(Step.next, 15.seconds);
        }
    }

    private void fail(ref CreatureContext me)
    {
        if (will && me.alive(will))
            me.despawn(will);
        foreach (c; challengers)
            if (c && me.alive(c))
                me.despawn(c);
        reset();
    }

    private void reset()
    {
        inProgress = false;
        stage = ready = 0;
        player = will = EntityRef.init;
        challengers[] = EntityRef.init;
        steps.clear();
    }
}

/**
 * Wizzlecrank's Shredder: driven by Pilot Wizzlecrank out of the Venture Co. drill
 * (`script_waypoint` 3439), mercenaries trying to stop it; at the end it breaks down and the pilot
 * climbs out (the quest's event).
 */
@creature("npc_wizzlecranks_shredder")
struct WizzlecranksShredder
{
    enum uint questEscape = 863, factionRatchet = 637, pilotWizz = 3451, mercenary = 3282;
    enum : int
    {
        sayStart = -1000298, sayStartup1 = -1000299, sayStartup2 = -1000300, sayMercenary = -1000301,
        sayProgress1 = -1000302, sayProgress2 = -1000303, sayProgress3 = -1000304, sayEnd = -1000305,
    }

    enum Step : ubyte { postEvent }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    ubyte postEvent, mercenariesLeft;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questEscape || escort.active)
            return;
        me.say(sayStart);
        me.setFaction(factionRatchet);
        postEvent = 0;
        escort.start(me, e.player, e.quest, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 1:
            me.say(sayStartup1, escort.player);
            break;
        case 9:
            me.say(sayStartup2, escort.player); // as it sets off for the next
            break;
        case 10:
            escort.run = false;
            break;
        case 18:
            if (const merc = me.summon(mercenary, Location(1128.489f, -3037.611f, 92.701f, 1.472f), 120_000))
            {
                me.sayOther(merc, sayMercenary);
                me.attack(merc, me.self);
                mercenariesLeft = 1;
                if (const other = me.summon(mercenary, Location(1160.172f, -2980.168f, 97.313f, 3.690f), 120_000))
                {
                    me.attack(other, me.self);
                    ++mercenariesLeft;
                }
            }
            if (!mercenariesLeft)
                runOn(me);
            break;
        case 25:
            steps.every(Step.postEvent, 1.seconds, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        if (e.summoned.entry == mercenary && mercenariesLeft && --mercenariesLeft == 0)
            runOn(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            return;
        switch (postEvent++)
        {
        case 0: me.say(sayProgress2); break;
        case 1: me.say(sayProgress3, escort.player); break;
        case 2: me.say(sayEnd); break;
        case 3:
            me.groupQuestEvent(escort.player, questEscape);
            me.summon(pilotWizz, Location.init, 180_000);
            me.standState(StandState.dead);
            steps.cancel(Step.postEvent);
            break;
        default:
            steps.cancel(Step.postEvent);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }

    private void runOn(ref CreatureContext me)
    {
        me.say(sayProgress1, escort.player);
        escort.run = true;
    }
}

/**
 * Regthar Deathgate: "Counterattack!" (4021) brings Horde defenders and Kolkar invaders to the
 * Kolkar's camp, each dead one replaced after a while; once twenty Kolkar fall, Warlord Krom'zar comes
 * with two guards, and with him dead the Kolkar retreat. Twenty minutes, and it is over anyway.
 */
@creature("npc_regthar_deathgate")
struct RegtharDeathgate
{
    enum uint questCounterattack = 4021, warlordKromzar = 9456, hordeDefender = 9457, hordeAxeThrower = 9458,
        kolkarInvader = 9524, kolkarStormseer = 9523, killLimit = 20, askKromzar = 1, textId = 2533;
    enum : int { sayStart = -1010001, sayDefender = -1010002, yellRetreat = -1010003 }

    private static immutable Location[7] hordeAt = [
        Location(-307.23f, -1919.84f, 91.66f, 0.64f), Location(-281.15f, -1906.39f, 91.66f, 1.88f),
        Location(-270.09f, -1901.58f, 91.66f, 1.88f), Location(-275.24f, -1901.96f, 91.66f, 1.90f),
        Location(-295.84f, -1913.58f, 91.66f, 1.86f), Location(-221.61f, -1936.54f, 94.00f, 0.41f),
        Location(-226.65f, -1927.87f, 93.24f, 0.41f),
    ];
    private static immutable Location[3] kromzarAt = [
        Location(-281.19f, -1855.54f, 92.58f, 4.85f), Location(-283.66f, -1858.45f, 92.47f, 4.85f),
        Location(-286.50f, -1856.18f, 92.44f, 4.85f),
    ];
    private static immutable Location[15] kolkarAt = [
        Location(-290.26f, -1860.85f, 92.48f, 3.68f), Location(-311.46f, -1871.16f, 92.64f, 6.06f),
        Location(-321.75f, -1868.48f, 93.73f, 0.30f), Location(-338.12f, -1852.10f, 94.09f, 0.01f),
        Location(-311.46f, -1847.78f, 94.93f, 6.15f), Location(-292.02f, -1840.00f, 93.06f, 3.51f),
        Location(-267.14f, -1853.97f, 93.24f, 3.52f), Location(-267.68f, -1832.77f, 92.69f, 3.52f),
        Location(-279.70f, -1845.67f, 92.81f, 3.83f), Location(-338.99f, -1868.68f, 93.50f, 0.17f),
        Location(-210.28f, -1916.22f, 92.87f, 4.89f), Location(-209.09f, -1922.44f, 93.26f, 3.87f),
        Location(-206.64f, -1924.83f, 93.78f, 2.41f), Location(-283.57f, -1883.91f, 92.60f, 3.53f),
        Location(-197.50f, -1929.31f, 94.03f, 3.51f),
    ];

    enum Step : ubyte { pulse }
    Schedule!Step steps;
    bool started, kromzarOut;
    uint kills;
    int timeLeft;                     // ms until it is over anyway
    EntityRef[7] horde;
    int[7] hordeDue;                  // ms until a dead one's replacement comes; 0: none due
    EntityRef[15] kolkar;
    int[15] kolkarDue;
    EntityRef[3] kromzar;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questCounterattack) != QuestProgress.incomplete || started)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Where is Warlord Krom'zar?", askKromzar);
        me.sendGossip(e.player, textId, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action == askKromzar)
            begin(me, e.player);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest == questCounterattack)
            begin(me, e.player);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        if (!started)
            return;
        if (e.summoned.entry == warlordKromzar)
            return finish(me);
        foreach (i, ref h; horde)
            if (h == e.summoned)
            {
                h = EntityRef.init;
                uint dead;
                foreach (other; horde)
                    dead += !other;
                hordeDue[i] = dead > 4 ? 1000 : 12_000; // many down: sooner
                if (me.random(2))
                    me.say(sayDefender);
                return;
            }
        foreach (i, ref k; kolkar)
            if (k == e.summoned)
            {
                k = EntityRef.init;
                kolkarDue[i] = 10_000;
                ++kills;
                return;
            }
    }

    void on(ref CreatureContext me, Step step)
    {
        timeLeft -= 1000;
        if (timeLeft <= 0)
            return finish(me);
        if (kromzarOut)
            return;
        if (kills >= killLimit)
        {
            kromzar[0] = me.summon(kolkarInvader, kromzarAt[0]);
            kromzar[1] = me.summon(warlordKromzar, kromzarAt[1]);
            kromzar[2] = me.summon(kolkarStormseer, kromzarAt[2]);
            kromzarOut = true;
            return;
        }
        foreach (i, ref due; hordeDue)
            if (due > 0 && (due -= 1000) <= 0)
            {
                due = 0;
                horde[i] = me.summon(me.random(2) ? hordeDefender : hordeAxeThrower, hordeAt[i]);
            }
        foreach (i, ref due; kolkarDue)
            if (due > 0 && (due -= 1000) <= 0)
            {
                due = 0;
                kolkar[i] = me.summon(me.random(2) ? kolkarInvader : kolkarStormseer, kolkarAt[i]);
            }
    }

    private void begin(ref CreatureContext me, EntityRef player)
    {
        me.say(sayStart, player);
        me.closeGossip(player);
        if (started)
            return;
        this = RegtharDeathgate.init;
        started = true;
        timeLeft = 20 * 60_000;
        foreach (i, at; hordeAt)
            horde[i] = me.summon(me.random(2) ? hordeDefender : hordeAxeThrower, at);
        foreach (i, at; kolkarAt)
            kolkar[i] = me.summon(me.random(2) ? kolkarInvader : kolkarStormseer, at);
        steps.every(Step.pulse, 1.seconds);
    }

    private void finish(ref CreatureContext me)
    {
        me.say(yellRetreat);
        foreach (c; horde)
            if (c && me.alive(c))
                me.despawn(c, 60_000); // those still fighting have a minute
        foreach (c; kolkar)
            if (c && me.alive(c))
                me.despawn(c, 60_000);
        foreach (c; kromzar)
            if (c && me.alive(c))
                me.despawn(c, 60_000);
        this = RegtharDeathgate.init;
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.barrens;

    // Gilthares: the quest, his path, his freedom at its end; another escort left behind fails.
    auto g = Driven!self("npc_gilthares", 3465, 54);
    g.raise(QuestAccepted(hero, Gilthares.questFreeFromHold));
    assert(g.host.has("faction 232") && g.host.has("say -1000370") && g.host.has("npcflags 0"));
    g.walkTo(53);
    assert(g.host.has("say -1000371") && g.host.has("say -1000380") && g.host.has("event 898"));
    assert(g.host.has("despawn") && !g.busy);
    auto lost = Driven!self("npc_gilthares", 3465, 54);
    lost.raise(QuestAccepted(hero, Gilthares.questFreeFromHold));
    lost.host.distance = 80;
    lost.run(200);
    assert(lost.host.has("fail 898") && !lost.host.has("event 898"));

    // Fizzule: two flares, then a salute: a quest giver; two minutes later himself again.
    auto f = Driven!self("npc_taskmaster_fizzule", 7233);
    f.raise(SpellHit(hero, TaskmasterFizzule.spellFlare));
    f.raise(EmoteReceived(hero, TaskmasterFizzule.textEmoteSalute));
    assert(!f.host.has("npcflags 2"), "one flare is not enough");
    f.raise(SpellHit(hero, TaskmasterFizzule.spellFlare));
    assert(f.host.has("faction 35") && f.host.has("passive"));
    f.raise(EmoteReceived(hero, TaskmasterFizzule.textEmoteSalute));
    assert(f.host.has("npcflags 2") && f.host.has("emote 66"));
    f.run(120_000);
    assert(f.host.has("npcflags restored") && f.host.has("faction 0"));

    // Twiggy: six challengers, one at a time; a fallen one delays the next; then Big Will.
    auto t = Driven!self("npc_twiggy_flathead", 6248);
    t.raise(Signal(hero, TwiggyFlathead.signalStart));
    t.run(1000);
    assert(t.host.summons == 6);
    t.run(5000);
    assert(t.host.has("attack 6240 hero"));
    t.raise(SummonedDied(creatureRef(6240, 101), hero));
    assert(t.host.has("say -1000126"));
    foreach (_; 0 .. 6)
        t.run(25_000);
    assert(t.host.summons == 7 && t.host.has("move 6238 1"), "Big Will comes");
    t.run(15_000);
    assert(t.host.has("faction of 6238 32") && t.host.has("say as 6238 -1000123"));
    t.raise(SummonedDied(creatureRef(6238, 107), hero));
    assert(t.host.has("say -1000127") && !t.busy);

    // The shredder: mercenaries at point 18; it runs on once they are dead; the pilot at the end.
    auto s = Driven!self("npc_wizzlecranks_shredder", 3439, 25);
    s.raise(QuestAccepted(hero, WizzlecranksShredder.questEscape));
    s.walkTo(17);
    assert(s.host.has("say as 3282 -1000301") && s.host.has("attack 3282 3439"));
    s.raise(SummonedDied(creatureRef(3282, 101), hero));
    s.raise(SummonedDied(creatureRef(3282, 102), hero));
    assert(s.host.has("say -1000302"));
    s.walkTo(24);
    s.run(25_000);
    assert(s.host.has("say -1000305") && s.host.has("event 863") && s.host.has("summon 3451"));

    // Regthar: twenty Kolkar dead, Krom'zar comes; with him dead, the retreat.
    auto r = Driven!self("npc_regthar_deathgate", 3389);
    r.raise(QuestAccepted(hero, RegtharDeathgate.questCounterattack));
    assert(r.host.summons == 22);
    bool[EntityRef] killed;
    foreach (_; 0 .. 20)
    {
        foreach_reverse (c; r.host.summoned)
            if ((c.entry == 9523 || c.entry == 9524) && c !in killed)
            {
                killed[c] = true;
                r.raise(SummonedDied(c, hero));
                break;
            }
        r.run(10_000);
    }
    r.run(1000);
    assert(r.host.has("summon 9456"));
    foreach (c; r.host.summoned)
        if (c.entry == 9456)
            r.raise(SummonedDied(c, hero));
    assert(r.host.has("say -1010003") && !r.busy);
}
