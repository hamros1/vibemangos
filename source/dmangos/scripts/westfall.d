/**
 * Westfall: the Defias Traitor, who leads the player who takes "The Defias Brotherhood" (155) from
 * Sentinel Hill to the Deadmines' hidden entrance in Moonbrook along his escort path; and Daphne
 * Stilwell, who with the player on "The Defias Brotherhood"'s "Tome of Valor" (1651) holds her farm
 * against three waves of Defias raiders.
 */
module dmangos.scripts.westfall;

import dmangos.script;

/**
 * The Defias Traitor: taken on the quest, he says so and sets off; at Moonbrook he warns of thieves;
 * at the hideout he tells the player to report to Stoutmantle (the quest's event), waits, and goes.
 * Attacked on the way he calls for help; left behind or killed, the quest fails.
 */
@creature("npc_defias_traitor")
struct DefiasTraitor
{
    enum uint questDefiasBrotherhood = 155;
    enum : int
    {
        sayStart = -1000101,
        sayMoonbrook = -1000102,
        sayHideout = -1000103,
        sayAggro1 = -1000104,
        sayAggro2 = -1000105,
    }
    enum uint moonbrookPoint = 36; // the path's point 37; the hideout is its last

    Escort escort = { despawnAfterMs: 3000 }; // over, he goes back to Sentinel Hill

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questDefiasBrotherhood || escort.active)
            return;
        me.say(sayStart, e.player);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == moonbrookPoint)
            me.say(sayMoonbrook, escort.player);
        else if (point != uint.max && point + 1 == me.waypointCount)
        {
            me.say(sayHideout, escort.player);
            me.questEvent(escort.player, escort.quest);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (escort.active)
            me.say(me.random(2) ? sayAggro1 : sayAggro2, escort.player);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Daphne Stilwell: taken on the quest, she runs to her house (`script_waypoint`, points counted
 * from 1), takes her rifle, and at the door waits for the raiders: three waves of three, four and
 * five, fifty seconds apart, down the hill. She shoots from where she stands; each wave beaten she
 * cheers, the third beaten she goes on, puts her rifle back, and the quest's event happens.
 */
@creature("npc_daphne_stilwell")
struct DaphneStilwell
{
    enum uint questTomeOfValor = 1651, defiasRaider = 6180, rifle = 2511, spellShoot = 6660;
    /// `script_texts` rows.
    enum : int
    {
        yellDefiasStart = -1000412, yellDaphneStart = -1000413, sayStart = -1000293, sayWaveDown1 = -1000294,
        sayWaveDown2 = -1000295, sayWaveDown3 = -1000414, sayDown3 = -1000296, sayPrologue = -1000297,
    }
    /// Points of her path.
    enum : uint { wavesPoint = 4, riflePoint = 5, holdPoint = 7, cheerPoint = 8, prologuePoint = 9, rifleBackPoint = 12,
        completePoint = 16 }
    enum uint emoteCheer = 4;

    enum Step : ubyte { wave, shoot }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    ubyte wave;       /// waves sent
    ubyte raiders;    /// alive
    bool yelled;      /// the raiders' leader yelled
    bool beaten;      /// the three waves are

    /// Where the raiders come from, and the two spots of the way down each runs to.
    private static immutable Location[5] raiderFrom = [Location(-11428.520f, 1612.757f, 72.241f),
        Location(-11422.998f, 1616.106f, 74.153f), Location(-11430.354f, 1618.334f, 72.632f),
        Location(-11423.307f, 1621.033f, 74.224f), Location(-11427.141f, 1623.220f, 73.168f)];
    private static immutable Location[5] raiderVia = [Location(-11453.118f, 1554.380f, 53.100f),
        Location(-11449.692f, 1554.672f, 53.598f), Location(-11454.533f, 1558.679f, 52.497f),
        Location(-11449.488f, 1557.817f, 53.443f), Location(-11452.123f, 1559.800f, 52.890f)];
    private static immutable Location[5] raiderTo = [Location(-11475.067f, 1534.259f, 50.199f),
        Location(-11470.306f, 1533.835f, 50.267f), Location(-11471.954f, 1539.599f, 50.273f),
        Location(-11465.560f, 1534.399f, 50.649f), Location(-11467.391f, 1537.989f, 50.726f)];

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questTomeOfValor || escort.active)
            return;
        me.say(sayStart);
        wave = raiders = 0;
        yelled = beaten = false;
        escort.start(me, e.player, e.quest, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case wavesPoint:
            wave = 0;
            steps.after(Step.wave, 1.seconds);
            break;
        case riflePoint:
            me.equip(0, 0, rifle);
            me.sheath(Sheath.ranged);
            break;
        case holdPoint:
            escort.run = false;
            me.say(yellDaphneStart);
            me.combatMovement(false);
            escort.paused = !beaten;
            break;
        case cheerPoint:
            me.say(sayDown3);
            me.emote(emoteCheer);
            break;
        case prologuePoint:
            me.say(sayPrologue);
            me.combatMovement(true);
            break;
        case rifleBackPoint:
            me.restoreEquipment();
            me.sheath(Sheath.unarmed);
            break;
        case completePoint:
            me.questEvent(escort.player, escort.quest);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.wave:
            if (wave >= 3)
                return;
            ++wave;
            foreach (i; 0 .. wave + 2)
                if (const raider = me.summon(defiasRaider, raiderFrom[i], 30_000))
                {
                    ++raiders;
                    me.moveCreature(raider, raiderVia[i], i, true);
                    if (!yelled)
                    {
                        me.sayOther(raider, yellDefiasStart);
                        yelled = true;
                    }
                }
            if (wave < 3)
                steps.after(Step.wave, 50.seconds);
            else if (raiders == 0)
                allBeaten(); // none could come
            break;
        case Step.shoot:
            if (!me.inCombat)
                return;
            if (me.castSpell(spellShoot) != ActionResult.ok)
                steps.after(Step.shoot, 500.msecs);
            else
                steps.after(Step.shoot, 2.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.point < raiderVia.length) // half way down: on to the farm
            me.moveCreature(e.summoned, raiderTo[e.point], cast(uint) raiderVia.length, true);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.summoned.entry != defiasRaider || raiders == 0 || --raiders > 0)
            return;
        if (wave == 3)
            allBeaten();
        else
        {
            static immutable int[3] waveDown = [sayWaveDown1, sayWaveDown2, sayWaveDown3];
            me.say(waveDown[me.random(3)]);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.combatMovement(false);
        steps.after(Step.shoot, 0.msecs);
    }

    /// The third wave is beaten: she goes on (or does not stop at the door).
    private void allBeaten()
    {
        beaten = true;
        escort.paused = false;
        wave = 0;
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (escort.active)
            me.sheath(Sheath.ranged);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.fail(me);
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    auto d = Driven!(dmangos.scripts.westfall).make("npc_daphne_stilwell");
    d.host.pathLength = 17;
    d.raise(QuestAccepted(d.host.player, 1651));
    assert(d.host.did("say -1000293"));
    d.walk();
    assert(d.host.did("equip 0 0 2511") && d.host.did("say -1000413") && d.host.lastPoint == uint.max);
    assert(d.host.summons == 3 + 4 + 5, "three waves");
    assert(d.host.did("say of 6180 -1000412") && d.host.did("move other 6180 0"));
    d.raise(SummonedArrived(creatureRef(6180), 2));
    assert(d.host.did("move other 6180 5"));
    foreach (i; 0 .. 12)
        d.raise(SummonedDied(creatureRef(6180, i)));
    d.tick(100);
    d.walk();
    assert(d.host.did("say -1000296") && d.host.did("equip back") && d.host.did("event 1651") && d.host.did("despawn"));
}
