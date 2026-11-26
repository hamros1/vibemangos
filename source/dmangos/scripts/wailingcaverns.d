/**
 * Wailing Caverns (map 43): the Fanglords' deaths, and the Disciple of Naralex's awakening of
 * Naralex. Once the four Fanglords are slain, the disciple leads the players through the caverns to
 * Naralex (his escort path, `waypoint_path` 3678), fighting off two ambushes on the way; there he
 * performs the awakening ritual while Naralex's nightmares come out of the water, Mutanus the
 * Devourer last. With Mutanus dead, Naralex wakes, and both go.
 */
module dmangos.scripts.wailingcaverns;

import dmangos.script;

/// Creatures of the caverns.
enum : uint
{
    cobrahn = 3669,
    pythas = 3670,
    anacondra = 3671,
    serpentis = 3673,
    disciple = 3678,
    naralex = 3679,
    mutanus = 3654,
    ravager = 3636,
    viper = 5755,
    moccasin = 5762,
    ectoplasm = 5763,
}

/// What the caverns remember: the Fanglords slain, and whether Naralex is awake (`instance.data`).
@instance("instance_wailing_caverns")
struct WailingCaverns
{
    /// Signals: to the disciple, the Fanglords slain; from him, Naralex awake. The copy's own are above the data
    /// fields its creatures' EventAI sets (`ACTION_T_SET_INST_DATA`: a Fanglord's 0 to 3, Mutanus's 5), as signals too.
    enum Signals : uint { fanglordsSlain = 1, naralexAwake = 100 }

    bool[4] fanglordDead;
    bool naralexAwake;
    @transient EntityRef discipleRef;

    private static immutable uint[4] fanglords = [cobrahn, pythas, anacondra, serpentis];

    private bool allSlain() const
    {
        foreach (dead; fanglordDead)
            if (!dead)
                return false;
        return true;
    }

    void on(ref InstanceContext caverns, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case disciple:
            discipleRef = e.creature;
            if (allSlain() && !naralexAwake)
                caverns.signal(e.creature, Signals.fanglordsSlain, 0); // no second call for aid
            break;
        case ravager, viper, DiscipleOfNaralex.adder, moccasin, ectoplasm, mutanus:
            // What the disciple called at a stop of his, whose deaths he waits for: kept with him in the checkpoint.
            if (e.summoned && discipleRef && caverns.alive(discipleRef) && !naralexAwake)
            {
                caverns.checkpointCreature(discipleRef);
                caverns.checkpointCreature(e.creature);
            }
            break;
        default:
            break;
        }
    }

    /**
     * A crash takes the disciple's summons with the old world, and his fight snapshot, kept apart from them, brought
     * him back waiting for their deaths for good. From his first stop the copy keeps him and them together in its
     * checkpoint; he leaves it when he goes.
     */
    void on(ref InstanceContext caverns, const ref Restored e)
    {
        if (caverns.hasSavedCreature(disciple))
            caverns.waitForPlayer();
    }

    void on(ref InstanceContext caverns, const ref CreatureDied e)
    {
        foreach (i, entry; fanglords)
            if (e.creature.entry == entry && !fanglordDead[i])
            {
                fanglordDead[i] = true;
                if (allSlain() && discipleRef)
                    caverns.signal(discipleRef, Signals.fanglordsSlain, 1); // his call for aid
            }
    }

    void on(ref InstanceContext caverns, const ref Signal e)
    {
        if (e.id == Signals.naralexAwake)
            naralexAwake = true;
    }
}

/**
 * The Disciple of Naralex (ScriptDev2's, from sniffs): see the module documentation. His path (`waypoint_path` 3678)
 * runs its points' database scripts (his lines on the way); he stops at three: the first corner (two raptors), the
 * circle of fire (his Cleansing, then three serpents), Naralex's chamber (the awakening ritual). He goes on from each
 * when what came is dead.
 */
@creature("npc_disciple_of_naralex")
struct DiscipleOfNaralex
{
    enum uint beginEvent = 1;
    enum : uint { textBegin = 699, textDisciple = 698 } /// his `npc_text`s, with the event's option and without
    /// `broadcast_text` rows.
    enum : uint
    {
        canBeAwakened = 2101, firstCorner = 1256, circleBanish = 1258, purified = 1259, beginRitual = 1264,
        ritualBegins = 1265, awakes = 1267, tosses = 1268, breaksThrough = 1269, vision = 1270, iAmAwake = 1271,
        thanks = 1272, farewell = 2103, aggro1 = 1273, aggro2 = 1277, aggroRitual = 1274, aggroMutanus = 1276,
    }
    enum : uint
    {
        spellMark = 5232, spellSleep = 1090, spellPotion = 8141, spellCleansing = 6270, spellAwakening = 6271,
        spellShapeshift = 8153,
    }
    enum : uint { emoteTalk = 1, emoteBow = 2, emoteBeg = 20, emotePoint = 25 }
    /// Points of his path (from 0: `waypoint_path`'s 12, 30 and 70).
    enum : uint { firstCorner_ = 11, circle = 29, chamber = 69 }

    static immutable Location[2] raptorsAt = [Location(-67.44779f, 214.5348f, -93.42037f),
        Location(-67.85276f, 203.7873f, -93.57328f)];
    static immutable Location[3] serpentsAt = [Location(-50.1237f, 274.7166f, -92.7608f, 3.0368f),
        Location(-60.2538f, 273.0981f, -92.7608f, 0.4014f), Location(-57.5452f, 280.2068f, -92.7608f, 5.0789f)];
    static immutable Location[3] moccasinsAt = [Location(171.39545f, 213.76605f, -105.50746f),
        Location(156.72229f, 189.91829f, -107.48995f), Location(121.39977f, 166.31746f, -105.54061f)];
    static immutable Location[7] ectoplasmsAt = [Location(162.06705f, 218.71494f, -105.36240f),
        Location(115.55489f, 168.22847f, -105.68655f), Location(82.065025f, 280.37723f, -103.29671f),
        Location(144.84305f, 278.07928f, -104.57445f), Location(155.84459f, 186.68817f, -107.08412f),
        Location(145.35356f, 219.34600f, -102.98572f), Location(164.62735f, 274.12335f, -107.29780f)];
    enum Location mutanusAt = Location(150.94276f, 262.79715f, -103.90348f);
    enum uint adder = 5048;

    enum Step : ubyte { event, potion, sleep }
    Schedule!Step steps;
    Escort escort;
    bool fanglordsSlain, done;
    uint stop;        /// the stop he is at (a point of his path above; 0: none)
    ubyte phase;      /// how far its subevent is
    ubyte alive;      /// what he summoned there, alive
    bool waitingForDead; /// he goes on when they are dead
    bool firstHit;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == WailingCaverns.Signals.fanglordsSlain && !fanglordsSlain)
        {
            fanglordsSlain = true;
            if (e.value)
                me.sayText(canBeAwakened);
        }
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.castSpell(spellMark, e.player, true);
        GossipMenu menu;
        const can = fanglordsSlain && !escort.active && !done;
        if (can)
            menu.add(GossipIcon.chat, "Let the event begin!", beginEvent);
        me.sendGossip(e.player, can ? textBegin : textDisciple, menu, true);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != beginEvent || escort.active || done || !fanglordsSlain)
            return;
        me.closeGossip(e.player);
        escort.runScripts = true; // his lines on the way
        escort.start(me, e.player, 0);
        me.setFaction(EscortFaction.neutralNeutralActive);
        steps.after(Step.potion, 5.seconds);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == firstCorner_ || point == circle || point == chamber)
        {
            if (point == firstCorner_)
                me.sayText(firstCorner);
            stop = point;
            phase = 0;
            escort.paused = true;
            steps.after(Step.event, (point == firstCorner_ ? 2000 : 1000).msecs);
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (alive && --alive == 0 && waitingForDead)
        {
            waitingForDead = false;
            steps.after(Step.event, 2.seconds);
        }
    }

    /// The next part of the stop's subevent; `wait` ms until the one after (0: when what came is dead).
    private void next(uint wait)
    {
        ++phase;
        if (wait)
            steps.after(Step.event, wait.msecs);
        else if (alive)
            waitingForDead = true;
        else
            steps.after(Step.event, 2.seconds);
    }

    private void summon(ref CreatureContext me, uint entry, Location at)
    {
        if (me.summon(entry, at, 0, me.self))
            ++alive;
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.potion:
            if (me.healthPercent < 80 && me.castSelf(spellPotion) == ActionResult.ok)
                steps.after(Step.potion, 45.seconds);
            else
                steps.after(Step.potion, 5.seconds);
            if (me.inCombat && !steps.pending(Step.sleep))
                steps.after(Step.sleep, 5.seconds);
            break;
        case Step.sleep:
            if (!me.inCombat)
                break;
            if (const target = me.selectTarget(Pick.random, 0, 1))
                if (me.castSpell(spellSleep, target) == ActionResult.ok)
                {
                    steps.after(Step.sleep, 30.seconds);
                    break;
                }
            steps.after(Step.sleep, 1.seconds);
            break;
        case Step.event:
            subevent(me);
            break;
        }
    }

    private void subevent(ref CreatureContext me)
    {
        const naralexRef = me.creatureNearby(naralex, 80);
        switch (stop)
        {
        case firstCorner_:
            if (phase == 0)
            {
                foreach (at; raptorsAt)
                    summon(me, ravager, at);
                next(0);
            }
            else
                resume(me);
            break;
        case circle:
            switch (phase)
            {
            case 0:
                me.sayText(circleBanish);
                me.castSelf(spellCleansing);
                next(20_000);
                break;
            case 1:
                foreach (at; serpentsAt)
                    summon(me, me.random(2) ? adder : viper, at);
                next(0);
                break;
            case 2:
                next(10_000);
                break;
            default:
                me.emote(emoteTalk);
                me.sayText(purified);
                resume(me);
                break;
            }
            break;
        case chamber:
            switch (phase)
            {
            case 0:
                me.sayText(beginRitual);
                me.emote(emoteBeg);
                me.combatMovement(false);
                next(5000);
                break;
            case 1:
                me.castSelf(spellAwakening);
                me.sayText(ritualBegins);
                next(3000);
                break;
            case 2:
                foreach (at; moccasinsAt)
                    summon(me, moccasin, at);
                next(5000);
                break;
            case 3:
                me.sayAs(naralexRef, tosses);
                next(0);
                break;
            case 4:
                foreach (at; ectoplasmsAt)
                    summon(me, ectoplasm, at);
                next(20_000);
                break;
            case 5:
                me.sayAs(naralexRef, breaksThrough);
                next(0);
                break;
            case 6:
                me.sayAs(naralexRef, vision);
                summon(me, mutanus, mutanusAt);
                next(0);
                break;
            case 7:
                // Mutanus is dead: Naralex wakes.
                if (naralexRef)
                    me.sayAs(naralexRef, iAmAwake);
                me.signalDungeon(WailingCaverns.Signals.naralexAwake);
                next(5000);
                break;
            case 8:
                me.interrupt();
                me.removeAura(me.self, spellAwakening);
                me.emote(emotePoint);
                me.sayText(awakes);
                next(1000);
                break;
            case 9:
                me.sayAs(naralexRef, thanks);
                next(7000);
                break;
            case 10:
                me.sayAs(naralexRef, farewell);
                next(3000);
                break;
            case 11:
                if (naralexRef)
                    me.castAs(naralexRef, spellShapeshift, naralexRef);
                me.castSelf(spellShapeshift);
                next(8000);
                break;
            case 12:
                // They fly off: he on along his path, Naralex after him.
                done = true;
                resume(me, true);
                if (naralexRef)
                    me.despawn(naralexRef, 30_000);
                me.despawn(30_000);
                break;
            default:
                break;
            }
            break;
        default:
            break;
        }
    }

    private void resume(ref CreatureContext me, bool run = false)
    {
        stop = 0;
        escort.run = run;
        escort.paused = false;
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (firstHit || !(escort.active || stop))
            return;
        firstHit = true;
        if (me.entryOf(e.enemy) == mutanus)
            me.sayText(aggroMutanus, e.enemy);
        else if (escort.point >= circle)
            me.sayText(aggroRitual, e.enemy);
        else
            me.sayText(me.random(10) ? aggro1 : aggro2, e.enemy);
        steps.after(Step.sleep, 5.seconds);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        firstHit = false;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        stop = 0;
        steps.clear();
    }
}
