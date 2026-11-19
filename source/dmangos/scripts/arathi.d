/**
 * Arathi Highlands: two escorts. Professor Phizzlethorpe leads the player on "Sunken Treasure" (665)
 * to the cave where he works his machine while the sea's surges come for him; Kinelory, on "Hints of
 * a New Plague?" (660), steals Quae's papers from Go'Shek Farm's cellar and runs back to Quae.
 */
module dmangos.scripts.arathi;

import dmangos.script;

/// `UnitFlags.immuneToNpc`: creatures leave it alone (and it them).
private enum uint immuneToNpc = 0x200;

/**
 * Professor Phizzlethorpe: he walks to the cave (`script_waypoint`, points counted from 1), talks
 * through his work, and calls up two Vengeful Surges that attack him; done, he runs out and the
 * quest's event happens. Left behind or killed, the quest fails.
 */
@creature("npc_professor_phizzlethorpe")
struct ProfessorPhizzlethorpe
{
    enum uint questSunkenTreasure = 665, vengefulSurge = 2776;
    enum uint factionBootyBay = 120;
    /// `script_texts` rows.
    enum : int
    {
        sayProgress1 = -1000264, sayProgress2 = -1000265, sayProgress3 = -1000266, emoteProgress4 = -1000267,
        sayAggro = -1000268, sayProgress5 = -1000269, sayProgress6 = -1000270, sayProgress7 = -1000271,
        emoteProgress8 = -1000272, sayProgress9 = -1000273,
    }

    Escort escort = { despawnAfterMs: 5000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questSunkenTreasure || escort.active)
            return;
        me.setFaction(factionBootyBay);
        me.say(sayProgress1, e.player);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const player = escort.player;
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case 5:
            me.say(sayProgress2, player);
            break;
        case 6:
            me.say(sayProgress3, player);
            break;
        case 9:
            me.say(emoteProgress4);
            break;
        case 10:
            me.summon(vengefulSurge, Location(-2056.41f, -2144.01f, 20.59f, 5.70f), 600_000, me.self);
            me.summon(vengefulSurge, Location(-2050.17f, -2140.02f, 19.54f, 5.17f), 600_000, me.self);
            break;
        case 11:
            me.say(sayProgress5, player);
            break;
        case 12:
            me.say(sayProgress6, player);
            escort.run = true;
            break;
        case 20:
            me.say(sayProgress7, player);
            break;
        case 21:
            me.say(emoteProgress8);
            me.say(sayProgress9, player);
            me.questEvent(player, escort.quest);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Kinelory: she sneaks down into the farm's cellar, finds Quae's papers, and runs back to Quae, to
 * whom she hands the pack (the quest's event at the last point). In a fight she takes bear form and
 * heals whichever of her and the player is hurt more.
 */
@creature("npc_kinelory")
struct Kinelory
{
    enum uint questHintsOfNewPlague = 660, jorell = 2733, quae = 2712;
    enum uint spellRejuvenation = 3627, spellBearForm = 4948;
    /// `script_texts` rows.
    enum : int
    {
        sayStart = -1000948, sayReachBottom = -1000949, sayAggro = -1000950, sayWatchBack = -1000952,
        emoteBelongings = -1000953, sayDataFound = -1000954, sayEscape = -1000955, sayFinish = -1000956,
        emoteHandPack = -1000957,
    }

    enum Step : ubyte { bearForm, heal }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 5000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questHintsOfNewPlague || escort.active)
            return;
        me.unitFlags(immuneToNpc, false);
        me.say(sayStart);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case 10:
            me.say(sayReachBottom);
            break;
        case 17:
            me.say(sayWatchBack);
            me.say(emoteBelongings);
            break;
        case 18:
            me.say(sayDataFound);
            break;
        case 19:
            me.say(sayEscape);
            me.face(escort.player);
            escort.run = true;
            break;
        case 34:
            me.say(sayFinish);
            me.unitFlags(immuneToNpc);
            if (const q = me.creatureNearby(quae, 10))
            {
                me.say(emoteHandPack, q);
                me.face(q);
            }
            break;
        case 35:
            me.questEvent(escort.player, escort.quest);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (e.enemy.entry != jorell && me.random(10) == 0)
            me.say(sayAggro);
        steps.after(Step.bearForm, (5000 + me.random(2001)).msecs);
        steps.after(Step.heal, (2000 + me.random(3001)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return steps.clear();
        final switch (step)
        {
        case Step.bearForm:
            if (me.castSelf(spellBearForm) == ActionResult.ok)
                steps.after(Step.bearForm, (25_000 + me.random(5001)).msecs);
            else
                steps.after(Step.bearForm, 1.seconds);
            break;
        case Step.heal:
            // The more hurt of her and the player she walks with.
            const mine = me.healthPercent, theirs = me.healthPercentOf(escort.player);
            const target = theirs < mine ? escort.player : me.self;
            if ((theirs < mine ? theirs : mine) < 100 && me.castSpell(spellRejuvenation, target) == ActionResult.ok)
                steps.after(Step.heal, (15_000 + me.random(10_001)).msecs);
            else
                steps.after(Step.heal, 1.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.fail(me);
    }
}

unittest
{
    import dmangos.scripts.testhost : Driven;

    alias zone = dmangos.scripts.arathi;
    auto p = Driven!zone.make("npc_professor_phizzlethorpe");
    p.host.pathLength = 21;
    p.raise(QuestAccepted(p.host.player, 665));
    assert(p.host.faction == 120 && p.host.did("say -1000264"));
    p.walk(9); // the database's point 10
    assert(p.host.log[$ - 2 .. $] == ["summon 2776", "summon 2776"]);
    p.walk();
    assert(p.host.did("say -1000273") && p.host.did("event 665") && p.host.did("despawn"));

    auto k = Driven!zone.make("npc_kinelory");
    k.host.pathLength = 35;
    k.raise(QuestAccepted(k.host.player, 660));
    assert(k.host.did("flags off 512") && k.host.did("say -1000948"));
    k.host.fighting = true;
    k.raise(EnteredCombat(EntityRef(0xF130_0000_0000_0001 | (ulong(2733) << 24)))); // Jorell: she says nothing
    assert(!k.host.did("say -1000950"));
    k.host.health = 50;
    k.tick(7000);
    assert(k.host.did("cast 4948") && k.host.did("cast 3627"));
    k.host.fighting = false;
    k.raise(Evaded());
    k.walk();
    assert(k.host.did("say -1000955") && k.host.did("event 660"));
}
