/**
 * Stormwind: Lady Katrana Prestor, whose advice the player on "The True Masters" (4185) seeks (the
 * conversation, three gossip steps, is the quest's event); Bartleby and Dashel Stonefist, who fight
 * the player on "Beat Bartleby" (1640) and "The Missing Diplomat" (1447) until they give up; Major
 * Mattingly and Field Marshal Afrasiabi, who talk of the dragon's head on its pike while it is there;
 * and "The Great Masquerade" (6403): Squire Rowe signals Reginald Windsor, who rides in, and leads the
 * player through the city to the keep, where he unmasks Lady Prestor as Onyxia.
 */
module dmangos.scripts.stormwind;

import dmangos.script;

/// Lady Katrana Prestor: her conversation for "The True Masters", and her usual menu otherwise.
@creature("npc_lady_katrana_prestor")
struct LadyKatranaPrestor
{
    enum uint questTrueMasters = 4185;
    enum : uint { textGreeting = 2693, textAdvice = 2694, textWarning = 2695, textFarewell = 2696 }
    enum : uint { askAdvice = 1, apologize = 2, beg = 3 }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questTrueMasters) != QuestProgress.incomplete)
            return; // her usual menu
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Pardon the intrusion, Lady Prestor, but Highlord Bolvar suggested that I seek your advice.",
            askAdvice);
        me.sendGossip(e.player, textGreeting, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        GossipMenu menu;
        switch (e.action)
        {
        case askAdvice:
            menu.add(GossipIcon.chat, "My apologies, Lady Prestor.", apologize);
            me.sendGossip(e.player, textAdvice, menu, false);
            break;
        case apologize:
            menu.add(GossipIcon.chat, "Begging your pardon, Lady Prestor. That was not my intent.", beg);
            me.sendGossip(e.player, textWarning, menu, false);
            break;
        case beg:
            me.sendGossip(e.player, textFarewell, menu, false);
            me.questEvent(e.player, questTrueMasters);
            break;
        default:
            break;
        }
    }
}

/// Faction 168: hostile to all.
private enum uint factionEnemy = 168;

/**
 * Bartleby: taken on the quest, he turns on the player; brought below 15% of his health (he cannot
 * die meanwhile), he gives up: the quest's event happens and he is himself again.
 */
@creature("npc_bartleby")
struct Bartleby
{
    enum uint questBeat = 1640;
    bool fighting;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questBeat || fighting)
            return;
        fighting = true;
        me.setFaction(factionEnemy);
        me.deathPrevention(true);
        me.attack(e.player);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!fighting || e.after >= 15)
            return;
        if (e.attacker.isPlayer)
            me.questEvent(e.attacker, questBeat);
        calm(me);
        me.evade();
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (fighting)
            calm(me);
    }

    private void calm(ref CreatureContext me)
    {
        fighting = false;
        me.deathPrevention(false);
        me.setFaction(0);
    }
}

/**
 * Dashel Stonefist: taken on the quest he threatens the player, two Old Town Thugs run in, and two
 * seconds on he attacks too. Brought to a fifth of his health (he cannot die meanwhile) he begs, stops,
 * goes back to his place and sends the thugs off, and the quest's event happens. Should he give up
 * the fight otherwise, the quest fails.
 */
@creature("npc_dashel_stonefist")
struct DashelStonefist
{
    enum uint questMissingDiplomat8 = 1447, oldTownThug = 4969;
    enum uint factionNeutral = 189, factionFriendlyToAll = 35, immuneToNpc = 0x200;
    /// `broadcast_text` rows.
    enum : uint { sayThreat = 1961, sayEnough = 1712, sayBackOff = 1713, sayThugSure = 1716, sayThugOkay = 1715 }
    enum uint emoteBeg = 20;
    /// `moveCreature` points of the thugs: at the player, back to their place.
    enum : uint { thugsAtPlayer = 1, thugsBack = 10 }

    private static immutable Location[2] thugFrom = [Location(-8687.311f, 446.7531f, 100.05593f, 5.12632f),
        Location(-8669.205f, 448.4405f, 99.74935f, 3.75387f)];
    private static immutable Location[2] thugTo = [Location(-8684.558f, 442.7352f, 99.480316f),
        Location(-8675.7f, 443.8787f, 99.641556f)];
    private static immutable Location[2] thugBack = [Location(-8686.397461f, 447.595703f, 99.994408f),
        Location(-8669.338867f, 448.362976f, 99.740005f)];

    enum Step : ubyte { attack, thugSure, thugOkay, thugsBack, done }
    Schedule!Step steps;
    EntityRef player;
    EntityRef[2] thugs;
    bool fighting, beaten;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questMissingDiplomat8 || fighting || beaten)
            return;
        me.sayText(sayThreat, e.player);
        me.setFaction(factionNeutral);
        me.npcFlags(0);
        me.reactState(Reaction.aggressive);
        player = e.player;
        foreach (i, ref thug; thugs)
            if ((thug = me.summon(oldTownThug, thugFrom[i], 120_000)) != EntityRef.init)
                me.moveCreature(thug, thugTo[i], thugsAtPlayer, true);
        fighting = true;
        steps.after(Step.attack, 2.seconds);
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.point == thugsAtPlayer && fighting)
            me.attack(e.summoned, player);
        else if (e.point == thugsBack)
        {
            me.face(e.summoned);
            me.despawn(e.summoned, 2000);
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        foreach (ref thug; thugs)
            if (thug == e.summoned)
                thug = EntityRef.init;
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!fighting || e.after > 20)
            return;
        // He has had enough.
        fighting = false;
        beaten = true;
        me.sayText(sayEnough);
        me.setFaction(factionFriendlyToAll);
        me.emote(emoteBeg);
        me.evade();
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (fighting)
        {
            // He gave up the fight unbeaten: the quest fails.
            me.failQuest(player, questMissingDiplomat8);
            foreach (thug; thugs)
                if (thug)
                    me.despawn(thug, 0);
            return over(me);
        }
        if (!beaten || steps.busy)
            return;
        me.sayText(sayBackOff);
        steps.after(thugs[0] || thugs[1] ? Step.thugSure : Step.done, 3.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.attack:
            if (!fighting)
                break;
            me.deathPrevention(true);
            me.attack(player);
            break;
        case Step.thugSure:
            if (thugs[0])
                me.sayAs(thugs[0], sayThugSure);
            steps.after(Step.thugOkay, 1500.msecs);
            break;
        case Step.thugOkay:
            if (thugs[1])
                me.sayAs(thugs[1], sayThugOkay);
            steps.after(Step.thugsBack, 1.seconds);
            break;
        case Step.thugsBack:
            foreach (i, thug; thugs)
                if (thug)
                    me.moveCreature(thug, thugBack[i], thugsBack);
            steps.after(Step.done, 2500.msecs);
            break;
        case Step.done:
            me.questEvent(player, questMissingDiplomat8);
            over(me);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        foreach (thug; thugs)
            if (thug)
                me.despawn(thug, 0);
        over(me);
    }

    private void over(ref CreatureContext me)
    {
        fighting = beaten = false;
        player = EntityRef.init;
        thugs[] = EntityRef.init;
        steps.clear();
        me.deathPrevention(false);
        me.setFaction(0);
        me.restoreNpcFlags();
        me.reactState(Reaction.passive);
    }
}

/// The heads on their pikes in Stormwind: Onyxia's (Major Mattingly's), Nefarian's (Field Marshal Afrasiabi's).
private enum uint headOfOnyxia = 179558, headOfNefarian = 179882;

/// Major Mattingly: while Onyxia's head hangs in Stormwind, he talks of it.
@creature("npc_major_mattingly")
struct MajorMattingly
{
    enum uint menuHead = 5754;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!me.objectNearby(headOfOnyxia, 100))
            return;
        me.gossipMenu(e.player, menuHead);
        me.consume();
    }
}

/// Field Marshal Afrasiabi: while Nefarian's head hangs in Stormwind, he talks of it.
@creature("npc_field_marshal_afrasiabi")
struct FieldMarshalAfrasiabi
{
    enum uint menuHead = 6027;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!me.objectNearby(headOfNefarian, 100))
            return;
        me.gossipMenu(e.player, menuHead);
        me.consume();
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.stormwind;
    auto b = Driven!zone.make("npc_bartleby");
    b.raise(QuestAccepted(b.host.player, 1640));
    assert(b.host.faction == 168 && b.host.did("attack 0 0"));
    b.raise(Damaged(b.host.player, 10, 20, 14));
    assert(b.host.did("event 1640") && b.host.did("evade") && b.host.faction == 0);

    auto d = Driven!zone.make("npc_dashel_stonefist");
    d.raise(Spawned());
    d.raise(QuestAccepted(d.host.player, 1447));
    assert(d.host.did("text 1961") && d.host.summons == 2 && d.host.did("move other 4969 1"));
    d.raise(SummonedArrived(creatureRef(4969, 1), 1));
    assert(d.host.did("attack 4969 0"));
    d.tick(2000);
    assert(d.host.did("death prevention true"));
    d.raise(Damaged(d.host.player, 10, 30, 20));
    assert(d.host.did("text 1712") && d.host.faction == 35 && d.host.did("evade"));
    d.raise(Reset());
    d.tick(10_000);
    assert(d.host.did("text 1713") && d.host.did("text of 4969 1716") && d.host.did("event 1447"));
    assert(!d.host.did("fail 1447") && d.host.did("npc flags back"));

    auto m = Driven!zone.make("npc_major_mattingly");
    m.raise(GossipHello(m.host.player));
    assert(!m.host.did("menu 5754"));
    m.host.nearby[179558] = EntityRef(0xF110_0000_0000_0000 | (ulong(179558) << 24) | 1);
    m.raise(GossipHello(m.host.player));
    assert(m.host.did("menu 5754"));
}

/// The "Great Masquerade" quests, and Reginald Windsor.
enum uint questStormwindRendezvous = 6402, questGreatMasquerade = 6403, reginaldWindsor = 12580;
/// `Signal`s from Squire Rowe to Windsor: get off the horse; welcome the player (and give the quest).
enum WindsorSignal : uint { dismount = 1, welcome }

/**
 * Squire Rowe: asked by a player who handed in "Stormwind Rendezvous" (or has it done), he walks out
 * of the gate, kneels, sends up a firework and Reginald Windsor rides in; Windsor gets off his horse,
 * welcomes the player and gives "The Great Masquerade". While Windsor is about, Rowe says so.
 */
@creature("npc_squire_rowe")
struct SquireRowe
{
    enum int saySignalSent = -1000822, sayDismount = -1000823, sayWelcome = -1000824;
    enum : uint { textDefault = 9063, textInProgress = 9064, textStart = 9065 }
    enum uint spellBlueFirework = 11540, actionSignal = 1, pointWindsorHere = 1;

    enum Step : ubyte { dismount, sayDismount, welcome }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    EntityRef windsor;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        const rendezvous = me.questStatus(e.player, questStormwindRendezvous),
            masquerade = me.questStatus(e.player, questGreatMasquerade);
        const done = masquerade == QuestProgress.complete || masquerade == QuestProgress.rewarded;
        GossipMenu menu;
        if (rendezvous == QuestProgress.complete || (rendezvous == QuestProgress.rewarded && !done))
        {
            if (inProgress(me))
                me.sendGossip(e.player, textInProgress, menu);
            else
            {
                menu.add(GossipIcon.chat, "Let Marshal Windsor know that I am ready.", actionSignal);
                me.sendGossip(e.player, textStart, menu);
            }
        }
        else
            me.sendGossip(e.player, textDefault, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.closeGossip(e.player);
        if (e.action != actionSignal || inProgress(me) || escort.active)
            return;
        windsor = EntityRef.init;
        escort.start(me, e.player, 0, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case 3:
            me.standState(StandState.kneel);
            break;
        case 4:
            me.castSelf(spellBlueFirework, true);
            me.standState(StandState.stand);
            windsor = me.summon(reginaldWindsor, Location(-9145.68f, 373.79f, 90.64f));
            if (windsor)
                me.moveCreature(windsor, Location(-9050.39f, 443.55f, 93.05f), pointWindsorHere, true);
            break;
        case 7:
            me.say(saySignalSent);
            escort.paused = true;
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.summoned == windsor && e.point == pointWindsorHere)
            steps.after(Step.dismount, 3.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.dismount:
            me.signal(windsor, WindsorSignal.dismount);
            steps.after(Step.sayDismount, 1.seconds);
            break;
        case Step.sayDismount:
            me.sayOther(windsor, sayDismount);
            steps.after(Step.welcome, 4.seconds);
            break;
        case Step.welcome:
            me.sayOther(windsor, sayWelcome, escort.player);
            me.signal(windsor, WindsorSignal.welcome);
            escort.paused = false;
            break;
        }
    }

    /// Whether Windsor is about.
    private bool inProgress(ref CreatureContext me)
    {
        return windsor && me.distanceTo(windsor) < float.infinity && me.alive(windsor);
    }
}

/**
 * Reginald Windsor: summoned by Squire Rowe, he gives "The Great Masquerade" once he has welcomed the
 * player. Taken on it he tells the player to get ready, rides to the gate (`script_waypoint`, points
 * counted from 1) and talks with Jonathan the Revelator, then marches through the city; before the
 * keep he waits until the player says so. In the keep he speaks with Bolvar, faces Lady Prestor and
 * reads the tablets: she shows her true face, her guards turn on Bolvar, she strikes Windsor down and
 * flies off. Her guards beaten, Bolvar kneels by Windsor, who dies: the quest's event.
 */
@creature("npc_reginald_windsor")
struct ReginaldWindsor
{
    enum uint jonathan = 466, wrynn = 1747, bolvar = 1748, prestor = 1749, royalGuard = 1756,
        onyxiaGuard = 12739;
    enum uint spellWindsorInspiration = 20273, spellWindsorRead = 20358, spellOnyxiaTransform = 20409,
        spellDismissHorse = 20000, spellShieldWall = 871, spellHammerOfJustice = 10308, spellStrongCleave = 8255;
    enum uint npcFlagGossip = 1, npcFlagQuestGiver = 2, uninteractible = 0x0200_0000, actionKeep = 1;
    enum uint textMasquerade = 5633;
    enum uint emoteKneel = 16, emotePoint = 25;

    /// Who says a line of the scene.
    enum Speaker : ubyte { none, windsor, jonathan, prestor, bolvar }
    private static struct Line
    {
        Speaker speaker;
        int text;   /// `script_texts` row; 0: an action only
        uint delay; /// ms to the next line; 0: the scene waits for something to happen
    }
    private static immutable Line[51] lines = [
        // the quest taken
        Line(Speaker.windsor, -1000825, 7000), Line(Speaker.windsor, -1000826, 6000),
        Line(Speaker.prestor, -1000827, 0),
        // at the gate
        Line(Speaker.jonathan, -1000828, 5000), Line(Speaker.windsor, -1000829, 6000),
        Line(Speaker.windsor, -1000830, 5000), Line(Speaker.jonathan, -1000831, 3000),
        Line(Speaker.jonathan, -1000832, 6000), Line(Speaker.jonathan, -1000833, 7000),
        Line(Speaker.windsor, -1000834, 8000), Line(Speaker.windsor, -1000835, 6000),
        Line(Speaker.jonathan, -1000836, 7000), Line(Speaker.jonathan, -1000837, 6000),
        Line(Speaker.jonathan, -1000838, 5000), Line(Speaker.none, 0, 4000), Line(Speaker.jonathan, -1000839, 3000),
        Line(Speaker.none, 0, 6000), Line(Speaker.none, 0, 3000), Line(Speaker.windsor, -1000840, 5000),
        Line(Speaker.windsor, -1000841, 3000), Line(Speaker.none, 0, 3000), Line(Speaker.none, 0, 0),
        // before the keep
        Line(Speaker.none, 0, 3000), Line(Speaker.windsor, -1000849, 0),
        Line(Speaker.windsor, -1000850, 4000), Line(Speaker.none, 0, 0),
        // in the keep
        Line(Speaker.none, 0, 3000), Line(Speaker.windsor, -1000851, 3000), Line(Speaker.bolvar, -1000852, 2000),
        Line(Speaker.windsor, -1000853, 4000), Line(Speaker.prestor, -1000854, 4000),
        Line(Speaker.prestor, -1000855, 9000), Line(Speaker.prestor, -1000856, 7000),
        Line(Speaker.windsor, -1000857, 6000), Line(Speaker.windsor, -1000858, 6000),
        Line(Speaker.windsor, -1000859, 4000), Line(Speaker.windsor, -1000860, 5000),
        Line(Speaker.windsor, -1000861, 3000), Line(Speaker.none, 0, 10_000), Line(Speaker.bolvar, -1000862, 3000),
        Line(Speaker.prestor, -1000863, 4000), Line(Speaker.bolvar, -1000864, 3000),
        Line(Speaker.prestor, -1000865, 2000), Line(Speaker.none, 0, 1500), Line(Speaker.none, 0, 400),
        Line(Speaker.windsor, -1000866, 4000), Line(Speaker.prestor, -1000868, 0),
        // her guards beaten
        Line(Speaker.none, 0, 14_000), Line(Speaker.none, 0, 2000), Line(Speaker.bolvar, -1000869, 6000),
        Line(Speaker.none, 0, 0),
    ];
    /// Places in `lines` the scene starts at or acts on.
    enum At : ubyte
    {
        questTaken = 0, seize = 2, gate = 3, jonathanKneels = 16, point = 20, onFromGate = 21, beforeKeep = 22,
        keepReady = 23, toKeep = 24, onToKeep = 25, keep = 26, wrynnFlees = 28, read = 38, transform = 39,
        bolvarHelps = 40, guardsTurn = 42, windsorKneels = 44, windsorFalls = 45, prestorFlies = 46,
        guardsBeaten = 47, bolvarKneels = 48, death = 49, end = 50,
    }
    static assert(lines.length == At.end + 1);

    private static immutable Location[2] jonathanSpots = [Location(-8967.960f, 510.008f, 96.351f),
        Location(-8974.590f, 516.213f, 96.590f)];
    private enum Location jonathanHome = Location(-8953.95f, 521.019f, 96.5399f);
    private static immutable Location[6] guardsAt = [Location(-8968.510f, 512.556f, 96.352f, 3.849f),
        Location(-8969.780f, 515.012f, 96.593f, 3.955f), Location(-8972.410f, 518.228f, 96.594f, 4.281f),
        Location(-8965.170f, 508.565f, 96.352f, 3.825f), Location(-8962.960f, 506.583f, 96.593f, 3.802f),
        Location(-8961.080f, 503.828f, 96.593f, 3.465f)];
    private enum Location wrynnSafe = Location(-8505.770f, 338.312f, 120.886f),
        bolvarHelp = Location(-8448.690f, 337.074f, 121.330f), bolvarKneel = Location(-8448.279f, 338.398f, 121.329f),
        bolvarHome = Location(-8439.98f, 329.392f, 122.579f);

    enum Step : ubyte { line, hammer, cleave }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 0 };
    EntityRef player;
    ubyte line;
    ubyte guards;     /// Onyxia's guards alive
    bool keepReady;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.npcFlags(0); // his quest is given when Squire Rowe has had him welcome the player
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == WindsorSignal.dismount)
        {
            me.mount(0);
            me.castSelf(spellDismissHorse);
        }
        else if (e.id == WindsorSignal.welcome)
            me.npcFlags(npcFlagQuestGiver);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questGreatMasquerade || player)
            return;
        player = e.player;
        me.npcFlags(0);
        say(me, At.questTaken);
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!keepReady || me.questStatus(e.player, questStormwindRendezvous) != QuestProgress.rewarded)
            return;
        const masquerade = me.questStatus(e.player, questGreatMasquerade);
        if (masquerade == QuestProgress.complete || masquerade == QuestProgress.rewarded)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "I am ready, as are my forces. Let us end this masquerade!", actionKeep);
        me.sendGossip(e.player, textMasquerade, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != actionKeep || !keepReady)
            return;
        me.closeGossip(e.player);
        keepReady = false;
        me.npcFlags(0);
        say(me, At.toKeep);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case 1:
            foreach (at; guardsAt)
                me.summon(royalGuard, at, 180_000);
            if (const j = me.creatureNearby(jonathan, 80))
                me.moveCreature(j, jonathanSpots[0], 0, true);
            break;
        case 2:
            escort.paused = true;
            say(me, At.gate);
            break;
        case 4:
            me.castSelf(spellWindsorInspiration, true);
            break;
        case 12:
            if (const j = me.creatureNearby(jonathan, 200))
                me.moveCreature(j, jonathanHome, 0);
            break;
        case 23:
            escort.paused = true;
            say(me, At.beforeKeep);
            break;
        case 26:
            escort.paused = true;
            say(me, At.keep);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.summoned.entry != onyxiaGuard || guards == 0)
            return;
        if (--guards == 0 && line == At.guardsBeaten)
            say(me, At.guardsBeaten);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(spellShieldWall);
        steps.after(Step.hammer, (me.random(1001)).msecs);
        steps.after(Step.cleave, (1000 + me.random(2001)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.line:
            say(me, cast(At) line);
            break;
        case Step.hammer:
            if (me.inCombat)
                steps.after(step, me.castSpell(spellHammerOfJustice) == ActionResult.ok ? 60.seconds : 1.seconds);
            break;
        case Step.cleave:
            if (me.inCombat)
                steps.after(step, me.castSpell(spellStrongCleave) == ActionResult.ok
                    ? (1000 + me.random(4001)).msecs : 1.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.fail(me);
    }

    /// A creature of the scene, if it is near.
    private EntityRef who(ref CreatureContext me, Speaker speaker)
    {
        final switch (speaker)
        {
        case Speaker.none:
            return EntityRef.init;
        case Speaker.windsor:
            return me.self;
        case Speaker.jonathan:
            return me.creatureNearby(jonathan, 80);
        case Speaker.prestor:
            return me.creatureNearby(prestor, 100);
        case Speaker.bolvar:
            return me.creatureNearby(bolvar, 100);
        }
    }

    /// Says line `at` of the scene (by whoever says it), does what goes with it, and goes on.
    private void say(ref CreatureContext me, At at)
    {
        const l = lines[at];
        if (l.speaker == Speaker.windsor)
            me.say(l.text, at == At.questTaken ? player : EntityRef.init);
        else if (l.speaker != Speaker.none)
            if (const speaker = who(me, l.speaker))
                me.sayOther(speaker, l.text);
        act(me, at);
        line = cast(ubyte)(at + 1);
        if (l.delay)
            steps.after(Step.line, l.delay.msecs);
    }

    /// What happens at line `at` besides the words.
    private void act(ref CreatureContext me, At at)
    {
        switch (at)
        {
        case At.seize:
            escort.start(me, player, questGreatMasquerade);
            break;
        case At.jonathanKneels:
            if (const j = who(me, Speaker.jonathan))
                me.moveCreature(j, jonathanSpots[1], 0);
            break;
        case At.point:
            me.emote(emotePoint);
            break;
        case At.onFromGate:
            me.removeAura(me.self, spellWindsorInspiration);
            escort.paused = false;
            break;
        case At.keepReady:
            keepReady = true;
            me.npcFlags(npcFlagGossip);
            break;
        case At.onToKeep:
            escort.paused = false;
            break;
        case At.wrynnFlees:
            if (const w = me.creatureNearby(wrynn, 100))
            {
                me.moveCreature(w, wrynnSafe, 0, true);
                me.despawn(w, 15_000);
            }
            break;
        case At.read:
            me.castSelf(spellWindsorRead);
            break;
        case At.transform:
            if (const p = who(me, Speaker.prestor))
                me.castSpell(spellOnyxiaTransform, p, true);
            break;
        case At.bolvarHelps:
            if (const b = who(me, Speaker.bolvar))
                me.moveCreature(b, bolvarHelp, 0, true);
            break;
        case At.guardsTurn:
            // Her guards show what they are, and go for Bolvar.
            const b = who(me, Speaker.bolvar);
            guards = 0;
            foreach (i; 0 .. 4)
            {
                const spot = Location(bolvarHelp.x - 4 + i * 2.5f, bolvarHelp.y - 6, bolvarHelp.z);
                if (const g = me.summon(onyxiaGuard, spot, 300_000, b))
                {
                    ++guards;
                    if (i == 0)
                        me.sayOther(g, -1000872);
                }
            }
            break;
        case At.windsorKneels:
            me.emote(emoteKneel);
            break;
        case At.windsorFalls:
            if (const p = who(me, Speaker.prestor))
                me.sayOther(p, -1000867);
            // He falls, not dead yet.
            me.deathPrevention(true);
            me.reactState(Reaction.passive);
            me.unitFlags(uninteractible);
            me.standState(StandState.dead);
            break;
        case At.prestorFlies:
            if (const p = who(me, Speaker.prestor))
                me.despawn(p, 1000);
            if (guards == 0)
                steps.after(Step.line, 1.seconds); // nobody to beat
            break;
        case At.guardsBeaten:
            if (const b = who(me, Speaker.bolvar))
                me.moveCreature(b, bolvarHelp, 0, true);
            break;
        case At.bolvarKneels:
            if (const b = who(me, Speaker.bolvar))
                me.moveCreature(b, bolvarKneel, 0);
            break;
        case At.death:
            me.say(-1000870);
            me.say(-1000871);
            me.questEvent(player, questGreatMasquerade);
            break;
        case At.end:
            if (const b = who(me, Speaker.bolvar))
                me.moveCreature(b, bolvarHome, 0);
            escort.active = false;
            me.despawn(1000);
            break;
        default:
            break;
        }
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.stormwind;
    auto rowe = Driven!zone.make("npc_squire_rowe");
    rowe.host.progress = QuestProgress.complete;
    rowe.raise(GossipHello(rowe.host.player));
    assert(rowe.host.did("gossip 9065 1"));
    rowe.raise(GossipSelect(rowe.host.player, 0, 0, 1));
    rowe.host.pathLength = 7;
    rowe.walk();
    assert(rowe.host.did("summon 12580") && rowe.host.did("move other 12580 1") && rowe.host.did("say -1000822"));
    rowe.raise(SummonedArrived(creatureRef(12580, 1), 1));
    rowe.tick(8000);
    assert(rowe.host.did("signal 12580 1") && rowe.host.did("say of 12580 -1000824") && rowe.host.did("signal 12580 2"));

    auto w = Driven!zone.make("npc_reginald_windsor");
    w.raise(Spawned());
    w.raise(Signal(creatureRef(17804), WindsorSignal.welcome));
    assert(w.host.did("npc flags 2"));
    foreach (entry; [466, 1747, 1748, 1749])
        w.host.nearby[entry] = creatureRef(entry);
    w.host.pathLength = 27;
    w.raise(QuestAccepted(w.host.player, 6403));
    w.tick(13_000);
    assert(w.host.did("say of 1749 -1000827") && w.host.lastPoint == 0);
    w.walk(1, 100);
    assert(w.host.did("say of 466 -1000828") && w.host.summons == 6);
    w.tick(120_000);
    w.walk(22, 100);
    w.tick(3000);
    assert(w.host.did("say -1000849"), "before the keep");
    w.host.questProgress[6402] = QuestProgress.rewarded;
    w.raise(GossipHello(w.host.player));
    assert(w.host.did("gossip 5633 1"));
    w.raise(GossipSelect(w.host.player, 0, 0, 1));
    w.tick(4000);
    w.walk(25, 100);
    w.tick(120_000);
    assert(w.host.did("say of 1749 -1000868") && w.host.did("summon 12739"));
    assert(!w.host.did("event 6403"), "her guards are not beaten yet");
    foreach (i; 0 .. 4)
        w.raise(SummonedDied(creatureRef(12739, i)));
    w.tick(30_000);
    assert(w.host.did("say -1000870") && w.host.did("event 6403") && !w.host.did("fail 6403"));
}
