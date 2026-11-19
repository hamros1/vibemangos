/**
 * Western Plaguelands: the Scourge cauldrons, whose lords come out for the players on the cauldron
 * quests; and Highlord Taelan Fordring's story: his men turning on him when "Scarlet Subterfuge"
 * (5862) is handed in, and "In Dreams" (5944), his ride out of Hearthglen to the tower where Grand
 * Inquisitor Isillien kills him, and his father Tirion comes too late.
 */
module dmangos.scripts.westernplaguelands;

import dmangos.script;

/**
 * A Scourge cauldron: a player on its cauldron quest comes near, and the Cauldron Lord comes out while
 * the cauldron's guardian goes. Each of the four cauldrons is known by where it stands.
 */
@creature("npc_the_scourge_cauldron")
struct ScourgeCauldron
{
    private static struct Cauldron
    {
        Location at;
        uint[2] quests; /// the Alliance's and the Horde's
        uint lord;
    }

    private static immutable Cauldron[4] cauldrons = [
        Cauldron(Location(1726.79f, -1179.0f), [5216, 5229], 11075),  // Felstone Field: Bilemaw
        Cauldron(Location(1867.25f, -1563.51f), [5219, 5231], 11077), // Dalson's Tears: Malvinious
        Cauldron(Location(1680.6f, -2282.77f), [5225, 5235], 11078),  // Gahrron's Withering: Soulwrath
        Cauldron(Location(1474.86f, -1867.65f), [5222, 5233], 11076), // The Writhing Haunt: Razarch
    ];

    void on(ref CreatureContext me, const ref UnitInSight e)
    {
        if (!e.unit.isPlayer)
            return;
        const which = nearest(me.location);
        foreach (quest; which.quests)
            if (me.questStatus(e.unit, quest) == QuestProgress.incomplete)
            {
                me.summon(which.lord, Location.init, 600_000);
                me.die();
                return;
            }
    }

    private static ref immutable(Cauldron) nearest(Location here)
    {
        size_t best;
        float bestDistance = float.max;
        foreach (i, ref c; cauldrons)
        {
            const d = (c.at.x - here.x) ^^ 2 + (c.at.y - here.y) ^^ 2;
            if (d < bestDistance)
            {
                bestDistance = d;
                best = i;
            }
        }
        return cauldrons[best];
    }
}

/// Who is who in Taelan's story.
enum : uint
{
    taelanFordring = 1842,
    scarletCavalier = 1836,
    isillien = 1840,
    tirionFordring = 12126,
    crimsonElite = 12128,
}

/// `Signal`s between the three: Taelan sends the other two off (`value`: the player's guid), Isillien
/// kills Taelan and later calls Tirion, and Tirion tells Taelan he is there and that he has fought.
enum TaelanSignal : uint { startEscort = 1, killTaelan, callTirion, tirionAtTower, tirionFought }

/// `FACTION_ESCORT_N_FRIEND_PASSIVE`.
private enum uint factionEscortFriendPassive = 290;
private enum uint spellDevotionAura = 17232, spellCrusaderStrike = 14518, spellHolyStrike = 17143,
    spellHolyCleave = 18819, spellHolyLight = 15493, spellLayOnHands = 17233, spellTaelanSuffering = 18810,
    spellTaelanDeath = 18969;

/// A player's guid is its low part only (`EntityRef.isPlayer`): it fits a signal's value.
private int carry(EntityRef player) { return cast(int) cast(uint) player.guid; }
/// ditto
private EntityRef carried(int value) { return EntityRef(cast(uint) value); }

/**
 * Highlord Taelan Fordring. "Scarlet Subterfuge" handed in, he kneels, his cavalier turns on him, and
 * once that is over he gives "In Dreams". Taken on it, he leads the player out of the keep
 * (`script_waypoint`, points counted from 1), mounts, and rides to the tower, where Isillien and his
 * elites come out; after their words they fight. Brought to half his health, Isillien strikes him
 * down and turns on the player; two minutes on (or Isillien hurt enough) Tirion rides in, speaks with
 * Isillien and fights him, then kneels by his son: the quest's event.
 */
@creature("npc_taelan_fordring")
struct TaelanFordring
{
    enum uint questScarletSubterfuge = 5862, questInDreams = 5944, mountModel = 239;
    enum uint npcFlagQuestGiver = 2, uninteractible = 0x0200_0000;
    enum : uint { exitKeepPoint = 26, towerPoint = 56 }

    /// Who says a line of the story, and what is done with it.
    enum Speaker : ubyte { none, taelan, isillien, tirion }
    private static struct Line
    {
        Speaker speaker;
        int text;   /// `script_texts` row; 0: an action only
        uint delay; /// ms to the next line; 0: the story waits for something to happen
    }
    /// The lines, in order; their places are named by `At`.
    private static immutable Line[38] lines = [
        // "Scarlet Subterfuge" handed in
        Line(Speaker.none, 0, 3000), Line(Speaker.none, 0, 7000), Line(Speaker.taelan, -1001076, 2000),
        Line(Speaker.none, 0, 0), Line(Speaker.none, 0, 3000), Line(Speaker.taelan, -1001077, 0),
        // "In Dreams"
        Line(Speaker.taelan, -1001079, 6000), Line(Speaker.taelan, -1001080, 4000), Line(Speaker.none, 0, 0),
        Line(Speaker.taelan, -1001081, 2000), Line(Speaker.isillien, -1001082, 5000),
        Line(Speaker.taelan, -1001083, 4000), Line(Speaker.taelan, -1001084, 10_000),
        Line(Speaker.isillien, -1001085, 7000), Line(Speaker.isillien, -1001086, 5000),
        Line(Speaker.isillien, -1001087, 6000), Line(Speaker.isillien, -1001088, 3000),
        Line(Speaker.isillien, -1001089, 3000), Line(Speaker.none, 0, 0),
        Line(Speaker.isillien, -1001090, 1000), Line(Speaker.isillien, -1001091, 4000),
        Line(Speaker.isillien, -1001092, 10_000), Line(Speaker.isillien, -1001093, 0),
        // Tirion
        Line(Speaker.none, 0, 0), Line(Speaker.none, 0, 10_000), Line(Speaker.tirion, -1001094, 4000),
        Line(Speaker.isillien, -1001095, 6000), Line(Speaker.tirion, -1001096, 4000),
        Line(Speaker.tirion, -1001097, 3000), Line(Speaker.isillien, -1001098, 0),
        Line(Speaker.tirion, -1001099, 3000), Line(Speaker.none, 0, 3000), Line(Speaker.tirion, -1001100, 4000),
        Line(Speaker.tirion, -1001101, 5000), Line(Speaker.tirion, -1001102, 5000),
        Line(Speaker.tirion, -1001103, 6000), Line(Speaker.tirion, -1001104, 7000),
        Line(Speaker.tirion, -1001105, 0),
    ];
    /// Places in `lines` the story starts at or acts on.
    enum At : ubyte
    {
        cavalierTurns = 0, completeOne = 2, cavalierAttacks = 3, devotion = 4, completeTwo = 5,
        exitKeep = 6, mount = 8, reachTower = 9, isillienTwo = 11, isillienThree = 12, fight = 18, killTaelan = 19,
        attackPlayer = 22, tirionComes = 23, tirionArrived = 24, tirionFights = 29, epilogue = 30, epilogueEnd = 37,
    }
    static assert(lines.length == At.epilogueEnd + 1);

    enum Step : ubyte { line, holyCleave, holyStrike, crusaderStrike, holyLight }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 180_000 };
    ubyte line;                       /// the next line of the story
    EntityRef cavalier, isillienRef, tirionRef;
    bool scarletComplete, mounted, fightStarted, dead;

    void on(ref CreatureContext me, const ref QuestRewarded e)
    {
        if (e.quest == questScarletSubterfuge && !escort.active)
            say(me, At.cavalierTurns);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questInDreams || escort.active)
            return;
        this = TaelanFordring.init;
        escort.start(me, e.player, e.quest);
        me.say(-1001078); // remove your disguise
        me.setFaction(factionEscortFriendPassive);
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case exitKeepPoint:
            escort.paused = true;
            say(me, At.exitKeep);
            break;
        case towerPoint:
            escort.paused = true;
            say(me, At.reachTower);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        switch (e.id)
        {
        case TaelanSignal.callTirion:
            if (!tirionRef)
                say(me, At.tirionComes);
            break;
        case TaelanSignal.tirionAtTower:
            me.moveCreature(tirionRef, near(me), At.tirionArrived);
            break;
        case TaelanSignal.tirionFought:
            me.moveCreature(tirionRef, near(me), At.epilogue);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.summoned == tirionRef && (e.point == At.tirionArrived || e.point == At.epilogue))
            say(me, cast(At) e.point);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (mounted)
            me.mount(0);
        me.castSelf(spellDevotionAura);
        steps.after(Step.holyCleave, (11_000 + me.random(4001)).msecs);
        steps.after(Step.holyStrike, (6000 + me.random(2001)).msecs);
        steps.after(Step.crusaderStrike, (1000 + me.random(4001)).msecs);
        steps.after(Step.holyLight, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (fightStarted && !dead && e.after < 50)
        {
            dead = true;
            say(me, At.killTaelan);
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (mounted && !dead)
            me.mount(mountModel);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (dead)
        {
            // Struck down: he lies there.
            me.reactState(Reaction.passive);
            me.unitFlags(uninteractible);
            me.standState(StandState.dead);
        }
        else if (scarletComplete)
        {
            scarletComplete = false;
            say(me, At.devotion);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (step == Step.line)
            return say(me, cast(At) line);
        if (!me.inCombat || dead)
            return;
        final switch (step)
        {
        case Step.line:
            break;
        case Step.holyCleave:
            again(me, step, me.castSpell(spellHolyCleave), 11_000, 13_000);
            break;
        case Step.holyStrike:
            again(me, step, me.castSpell(spellHolyStrike), 9000, 14_000);
            break;
        case Step.crusaderStrike:
            again(me, step, me.castSpell(spellCrusaderStrike), 7000, 12_000);
            break;
        case Step.holyLight:
            if (me.healthPercent < 15 && !fightStarted)
                me.castSelf(spellLayOnHands);
            else if (me.healthPercent < 75)
                return again(me, step, me.castSelf(spellHolyLight), 10_000, 15_000);
            steps.after(step, 1.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.fail(me);
    }

    /// Says line `at` of the story (by whoever says it), does what goes with it, and goes on.
    private void say(ref CreatureContext me, At at)
    {
        const l = lines[at];
        final switch (l.speaker)
        {
        case Speaker.none:
            break;
        case Speaker.taelan:
            me.say(l.text);
            break;
        case Speaker.isillien:
            me.sayOther(isillienRef, l.text);
            break;
        case Speaker.tirion:
            me.sayOther(tirionRef, l.text);
            break;
        }
        act(me, at);
        line = cast(ubyte)(at + 1);
        if (l.delay)
            steps.after(Step.line, l.delay.msecs);
    }

    /// What happens at line `at` besides the words.
    private void act(ref CreatureContext me, At at)
    {
        const player = escort.player;
        switch (at)
        {
        case At.cavalierTurns:
            me.standState(StandState.kneel);
            me.npcFlags(0);
            cavalier = me.creatureNearby(scarletCavalier, 10);
            if (cavalier)
                me.sayOther(cavalier, -1001072 - cast(int) me.random(4));
            break;
        case At.completeOne:
            me.standState(StandState.stand);
            me.castSelf(spellTaelanSuffering);
            break;
        case At.cavalierAttacks:
            me.setFaction(factionEscortFriendPassive);
            if (cavalier)
                me.attack(cavalier, me.self);
            scarletComplete = true;
            break;
        case At.completeTwo:
            me.npcFlags(npcFlagQuestGiver);
            break;
        case At.mount:
            mounted = true;
            escort.paused = false;
            me.mount(mountModel);
            break;
        case At.reachTower:
            me.face(player);
            isillienRef = me.summon(isillien, Location(2693.12f, -1943.04f, 72.04f, 2.11f), 15 * 60_000);
            me.summon(crimsonElite, Location(2690.0f, -1945.5f, 72.04f, 2.11f), 15 * 60_000);
            me.summon(crimsonElite, Location(2697.5f, -1943.0f, 72.04f, 2.11f), 15 * 60_000);
            me.signal(isillienRef, TaelanSignal.startEscort, carry(player));
            break;
        case At.isillienTwo:
            me.face(isillienRef);
            break;
        case At.isillienThree:
            mounted = false;
            me.mount(0);
            break;
        case At.fight:
            static immutable Location[3] elitesFrom = [Location(2711.32f, -1882.67f, 67.89f, 3.2f),
                Location(2710.93f, -1878.90f, 67.97f, 3.2f), Location(2710.53f, -1875.28f, 67.90f, 3.2f)];
            foreach (at_; elitesFrom)
                me.summon(crimsonElite, at_, 15 * 60_000, me.self);
            me.attack(isillienRef, me.self);
            me.attack(isillienRef);
            fightStarted = true;
            break;
        case At.killTaelan:
            me.signal(isillienRef, TaelanSignal.killTaelan);
            me.evade();
            break;
        case At.attackPlayer:
            me.attack(isillienRef, player);
            break;
        case At.tirionComes:
            tirionRef = me.summon(tirionFordring, Location(2620.273f, -1920.917f, 74.25f), 15 * 60_000);
            me.signal(tirionRef, TaelanSignal.startEscort, carry(player));
            break;
        case At.tirionFights:
            me.attack(tirionRef, isillienRef);
            me.attack(isillienRef, tirionRef);
            break;
        case At.epilogueEnd:
            me.questEvent(player, questInDreams);
            me.despawn(tirionRef, 180_000);
            escort.active = false;
            me.despawn(180_000);
            break;
        default:
            break;
        }
    }

    /// A spot by him, for Tirion to come to.
    private static Location near(ref CreatureContext me)
    {
        const here = me.location;
        return Location(here.x + 1.5f, here.y + 1.5f, here.z);
    }

    private void again(ref CreatureContext me, Step step, ActionResult result, uint low, uint high)
    {
        steps.after(step, result == ActionResult.ok ? (low + me.random(high - low + 1)).msecs : 1.seconds);
    }
}

/**
 * Grand Inquisitor Isillien: called out of his tower by Taelan's coming, he walks out (his escort
 * path) and waits; he fights when told, strikes Taelan down when told, and two minutes later (or hurt
 * below a fifth) calls Tirion's coming.
 */
@creature("npc_isillien")
struct Isillien
{
    enum uint spellManaBurn = 15800, spellMindBlast = 17194, spellMindFlay = 17165, spellGreaterHeal = 10965;

    enum Step : ubyte { callTirion, mindBlast, mindFlay, manaBurn, greaterHeal }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 0 };
    EntityRef taelan;
    bool called;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.defensive); // he attacks only when told
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        switch (e.id)
        {
        case TaelanSignal.startEscort:
            taelan = e.from;
            escort.start(me, carried(e.value), 0);
            break;
        case TaelanSignal.killTaelan:
            me.castSpell(spellTaelanDeath, e.from, true);
            steps.after(Step.callTirion, 120.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (escort.reached(me, e) + 1 == 3) // out of the tower: he waits
            escort.paused = true;
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.mindBlast, (me.random(1001)).msecs);
        steps.after(Step.mindFlay, (3000 + me.random(4001)).msecs);
        steps.after(Step.manaBurn, (7000 + me.random(5001)).msecs);
        steps.after(Step.greaterHeal, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (e.after < 20 && taelan)
            callTirion(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (step == Step.callTirion)
            return callTirion(me);
        if (!me.inCombat)
            return;
        switch (step)
        {
        case Step.mindBlast:
            steps.after(step, me.castSpell(spellMindBlast) == ActionResult.ok ? (3000 + me.random(2001)).msecs : 1.seconds);
            break;
        case Step.mindFlay:
            steps.after(step, me.castSpell(spellMindFlay) == ActionResult.ok ? (9000 + me.random(4001)).msecs : 1.seconds);
            break;
        case Step.manaBurn:
            steps.after(step, me.castSpell(spellManaBurn, me.randomTarget) == ActionResult.ok
                ? (8000 + me.random(5001)).msecs : 1.seconds);
            break;
        case Step.greaterHeal:
            if (me.healthPercent < 50 && me.castSelf(spellGreaterHeal) == ActionResult.ok)
                steps.after(step, (15_000 + me.random(5001)).msecs);
            else
                steps.after(step, 1.seconds);
            break;
        default:
            break;
        }
    }

    private void callTirion(ref CreatureContext me)
    {
        if (called)
            return;
        called = true;
        steps.cancel(Step.callTirion);
        me.signal(taelan, TaelanSignal.callTirion);
    }
}

/**
 * Tirion Fordring: called by Taelan, he rides in (his escort path) to the tower, gets off his horse and
 * lets Taelan know; he fights Isillien when told, and after the fight goes to his son.
 */
@creature("npc_tirion_fordring")
struct TirionFordring
{
    enum Step : ubyte { holyCleave, holyStrike, crusaderStrike }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 0 };
    EntityRef taelan;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.defensive); // he attacks only when told
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != TaelanSignal.startEscort)
            return;
        taelan = e.from;
        escort.start(me, carried(e.value), 0, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (escort.reached(me, e) + 1 != 3)
            return;
        escort.active = false; // at the tower: Taelan brings him on
        me.mount(0);
        me.signal(taelan, TaelanSignal.tirionAtTower);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(spellDevotionAura);
        steps.after(Step.holyCleave, (11_000 + me.random(4001)).msecs);
        steps.after(Step.holyStrike, (6000 + me.random(2001)).msecs);
        steps.after(Step.crusaderStrike, (1000 + me.random(4001)).msecs);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
        me.signal(taelan, TaelanSignal.tirionFought);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return;
        final switch (step)
        {
        case Step.holyCleave:
            steps.after(step, me.castSpell(spellHolyCleave) == ActionResult.ok ? (12_000 + me.random(3001)).msecs : 1.seconds);
            break;
        case Step.holyStrike:
            steps.after(step, me.castSpell(spellHolyStrike) == ActionResult.ok ? (8000 + me.random(3001)).msecs : 1.seconds);
            break;
        case Step.crusaderStrike:
            steps.after(step, me.castSpell(spellCrusaderStrike) == ActionResult.ok ? (7000 + me.random(2001)).msecs : 1.seconds);
            break;
        }
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.westernplaguelands;

    // A cauldron: near Dalson's Tears, the player on its quest calls Malvinious out.
    auto c = Driven!zone.make("npc_the_scourge_cauldron");
    assert(ScourgeCauldron.nearest(Location(1860, -1560)).lord == 11077);
    c.host.progress = QuestProgress.none;
    c.raise(UnitInSight(c.host.player));
    assert(!c.host.did("die"));
    c.host.progress = QuestProgress.incomplete;
    c.raise(UnitInSight(c.host.player));
    assert(c.host.did("die") && c.host.did("summon 11075"), "the test host stands at Felstone Field's end");

    // Taelan: the whole story, with the others' parts played by hand.
    auto t = Driven!zone.make("npc_taelan_fordring");
    t.host.pathLength = 57;
    t.raise(QuestAccepted(t.host.player, 5944));
    assert(t.host.faction == 290 && t.host.did("say -1001078"));
    t.walk(25, 100);
    assert(t.host.did("say -1001079") && t.host.lastPoint == uint.max);
    t.tick(10_000);
    assert(t.host.did("mount 239"));
    t.walk(55, 100);
    assert(t.host.did("say -1001081"));
    t.tick(2000);
    assert(t.host.did("summon 1840") && t.host.did("signal 1840 1"));
    t.tick(47_000);
    assert(t.host.did("say of 1840 -1001089") && t.host.did("summon 12128") && t.host.did("attack 1840 1"));
    t.raise(Damaged(creatureRef(1840), 100, 60, 45));
    assert(t.host.did("say of 1840 -1001090") && t.host.did("signal 1840 2"));
    t.tick(20_000);
    assert(t.host.did("attack 1840 0"));
    t.raise(Signal(creatureRef(1840), TaelanSignal.callTirion));
    assert(t.host.did("summon 12126") && t.host.did("signal 12126 1"));
    t.raise(Signal(creatureRef(12126), TaelanSignal.tirionAtTower));
    assert(t.host.did("move other 12126 24"), "Tirion comes to him");
    t.raise(SummonedArrived(creatureRef(12126, t.host.summons), TaelanFordring.At.tirionArrived));
    t.tick(30_000);
    assert(t.host.did("say of 1840 -1001098") && t.host.did("attack 12126 1840"));
    t.raise(Signal(creatureRef(12126), TaelanSignal.tirionFought));
    t.raise(SummonedArrived(creatureRef(12126, t.host.summons), TaelanFordring.At.epilogue));
    t.tick(40_000);
    assert(t.host.did("say of 12126 -1001105") && t.host.did("event 5944") && !t.host.did("fail 5944"));
}
