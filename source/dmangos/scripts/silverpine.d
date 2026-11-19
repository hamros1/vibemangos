/**
 * Silverpine Forest: Deathstalker Erland, whom the player on "Escorting Erland" (435) takes to Rane
 * Yorick and Quinn Yorick; and Deathstalker Faerleia, who with the player on "Pyrewood Ambush" (452)
 * waits in Pyrewood's town hall for the council, which comes in four waves.
 */
module dmangos.scripts.silverpine;

import dmangos.script;

/**
 * Deathstalker Erland: he walks to the Yorick brothers' house (`script_waypoint`, points counted from
 * 1); there the quest's event happens, and he talks with Rane and then Quinn before saying goodbye.
 */
@creature("npc_deathstalker_erland")
struct DeathstalkerErland
{
    enum uint questErland = 435, rane = 1950, quinn = 1951;
    /// `script_texts` rows.
    enum : int
    {
        sayStart1 = -1000306, sayStart2 = -1000307, sayAggro1 = -1000308, sayEnd = -1000312, sayRane = -1000313,
        sayRaneReply = -1000314, sayCheckNext = -1000315, sayQuinn = -1000316, sayQuinnReply = -1000317,
        sayBye = -1000318,
    }

    Escort escort = { despawnAfterMs: 5000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questErland || escort.active)
            return;
        me.say(sayStart1);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const player = escort.player;
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case 2:
            me.say(sayStart2, player);
            break;
        case 14:
            me.say(sayEnd, player);
            me.questEvent(player, escort.quest);
            break;
        case 15:
            if (const r = me.creatureNearby(rane, 45))
                me.sayOther(r, sayRane, me.self);
            break;
        case 16:
            me.say(sayRaneReply);
            break;
        case 17:
            me.say(sayCheckNext);
            break;
        case 25:
            me.say(sayQuinn);
            break;
        case 26:
            if (const q = me.creatureNearby(quinn, 45))
                me.sayOther(q, sayQuinnReply, me.self);
            break;
        case 27:
            me.say(sayBye);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro1 - cast(int) me.random(3), e.enemy);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Deathstalker Faerleia: taken on the quest, she warns the player; ten seconds on the first
 * councilmen come in, and each wave once the last is dead: one, two, three, and the Lord Mayor with
 * two more. She drinks a potion after each; the last dead, the quest's event happens. Killed, the
 * quest fails.
 */
@creature("npc_deathstalker_faerleia")
struct DeathstalkerFaerleia
{
    enum uint questPyrewoodAmbush = 452, spellDrinkPotion = 3359;
    enum : int { sayStart = -1000553, sayCompleted = -1000554 }
    enum : uint
    {
        smithers = 2060, thather = 2061, hendricks = 2062, wilhelm = 2063, hartin = 2064, cooper = 2065,
        higarth = 2066, brunswick = 2067, morrison = 2068,
    }

    enum Step : ubyte { wave }
    Schedule!Step steps;
    EntityRef player;
    ubyte wave;  /// waves sent
    ubyte alive; /// of the last wave
    bool active;

    private static immutable Location[3] spawns = [Location(-397.45f, 1509.56f, 18.87f, 4.73f),
        Location(-398.35f, 1510.75f, 18.87f, 4.76f), Location(-396.41f, 1511.06f, 18.87f, 4.74f)];

    /// Each wave: who comes, and where (an index of `spawns`).
    private static immutable uint[2][][4] waves = [
        [[smithers, 1]],
        [[thather, 2], [hendricks, 1]],
        [[wilhelm, 1], [hartin, 0], [higarth, 2]],
        [[cooper, 1], [brunswick, 2], [morrison, 0]],
    ];
    /// How long after a wave is beaten the next comes (the first: after the quest is taken).
    private static immutable uint[4] pauses = [10_000, 10_000, 10_000, 8000];

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questPyrewoodAmbush || active)
            return;
        me.say(sayStart, e.player);
        me.npcFlags(0);
        player = e.player;
        active = true;
        wave = alive = 0;
        steps.after(Step.wave, pauses[0].msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!active || wave >= waves.length)
            return;
        foreach (who; waves[wave])
            if (me.summon(who[0], spawns[who[1]], 0, player))
                ++alive;
        ++wave;
        if (!alive) // none could come: on to the next
            beaten(me);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (!active || alive == 0)
            return;
        if (--alive == 0)
            beaten(me);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        if (!active)
            return;
        me.failQuest(player, questPyrewoodAmbush);
        finish(me);
    }

    private void beaten(ref CreatureContext me)
    {
        me.castSelf(spellDrinkPotion);
        if (wave < waves.length)
            return cast(void) steps.after(Step.wave, pauses[wave].msecs);
        me.say(sayCompleted);
        me.questEvent(player, questPyrewoodAmbush);
        finish(me);
    }

    private void finish(ref CreatureContext me)
    {
        active = false;
        player = EntityRef.init;
        steps.clear();
        me.restoreNpcFlags();
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.silverpine;
    auto erland = Driven!zone.make("npc_deathstalker_erland");
    erland.host.pathLength = 27;
    erland.host.nearby[1950] = creatureRef(1950);
    erland.raise(QuestAccepted(erland.host.player, 435));
    erland.walk();
    assert(erland.host.did("event 435") && erland.host.did("say of 1950 -1000313") && erland.host.did("say -1000318"));

    auto f = Driven!zone.make("npc_deathstalker_faerleia");
    f.raise(QuestAccepted(f.host.player, 452));
    f.tick(10_000);
    assert(f.host.did("summon 2060"));
    f.raise(SummonedDied(creatureRef(2060)));
    assert(f.host.did("cast 3359"));
    foreach (wave, size; [2, 3, 3])
    {
        f.tick(10_000);
        foreach (i; 0 .. size)
            f.raise(SummonedDied(creatureRef(2061)));
    }
    assert(f.host.did("summon 2068") && f.host.did("say -1000554") && f.host.did("event 452") && f.host.did("npc flags back"));
}
