/**
 * Darkshore: Kerlonian Evershade, who falls asleep on the way to Liladris ("The Sleeper Has Awakened",
 * 5321); the escorts of Prospector Remtravel ("Absent Minded Prospector", 731), Volcor ("Escape
 * Through Force", 994, and "Escape Through Stealth", 995) and Therylune ("Therylune's Escape", 945);
 * the Threshwackonator 4100, which follows the player to Gelkak and turns on him ("Gyromast's
 * Revenge", 2078); the rabid Thistle Bears caught in a trap ("Plagued Lands", 2118); and the
 * Blackwood furbolgs and their food stores.
 */
module dmangos.scripts.darkshore;

import dmangos.script;

/**
 * Kerlonian Evershade: follows the player to Liladris, falling asleep now and then until the Horn of
 * Awakening wakes him; near her, the quest is done.
 */
@creature("npc_kerlonian")
struct Kerlonian
{
    enum uint questSleeperAwakened = 5321, liladris = 11219;
    enum : uint { spellBearForm = 18309, spellSleepVisual = 25148, spellAwaken = 17536 }
    enum : int { sayStart = -1000434, emoteSleep1 = -1000435, saySleep1 = -1000438, emoteAwaken = -1000445, sayEnd = -1000444 }

    enum Step : ubyte { sleep, look }
    Schedule!Step steps;
    Follower follower;
    bool asleep;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(spellBearForm);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!follower.active)
            me.castSelf(spellBearForm);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questSleeperAwakened || follower.active)
            return;
        me.removeAura(me.self, spellBearForm);
        me.standState(StandState.stand);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        me.say(sayStart, e.player);
        follower.start(me, e.player, e.quest, EscortFaction.neutralFriendPassive);
        asleep = false;
        steps.after(Step.sleep, (10 + me.random(36)).seconds);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellAwaken || !e.caster.isPlayer || !follower.active || !asleep)
            return;
        asleep = false;
        me.removeAura(me.self, spellSleepVisual);
        me.standState(StandState.stand);
        me.say(emoteAwaken);
        follower.pause(me, false);
        steps.after(Step.sleep, (25 + me.random(66)).seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!follower.active)
            return steps.clear();
        final switch (step)
        {
        case Step.sleep:
            if (me.inCombat || asleep)
                return cast(void) steps.after(Step.sleep, 5.seconds);
            asleep = true;
            follower.pause(me, true);
            me.say(emoteSleep1 - cast(int) me.random(3));
            me.say(saySleep1 - cast(int) me.random(4));
            if (me.castSelf(spellSleepVisual) == ActionResult.ok)
                me.standState(StandState.sleep);
            break;
        case Step.look:
            if (me.inCombat || !me.creatureNearby(liladris, 25))
                break;
            if (me.questStatus(follower.player, questSleeperAwakened) == QuestProgress.incomplete)
                me.groupQuestEvent(follower.player, questSleeperAwakened);
            me.say(sayEnd);
            follower.complete(me);
            steps.clear();
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        follower.fail(me);
        steps.clear();
    }
}

/// Prospector Remtravel: led back from the Ruins of Mathystra (`script_waypoint` 2917).
@creature("npc_prospector_remtravel")
struct ProspectorRemtravel
{
    enum uint questAbsentMinded2 = 731;
    enum uint sayAggro1 = 938; /// to 943 (`broadcast_text`)

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questAbsentMinded2 || escort.active)
            return;
        me.setFaction(EscortFaction.alliancePassive);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const line = me.random(6);
        me.sayText(sayAggro1 + line, line ? e.enemy : EntityRef.init);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point + 1 == 38)
            me.groupQuestEvent(escort.player, questAbsentMinded2);
        else if (point + 1 == 39)
        {
            // Home: he stays a while, then goes back to his ruins.
            escort.active = false;
            me.restoreNpcFlags();
            me.despawn(60_000);
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * The Threshwackonator 4100: its key turned, it follows the player; near Gelkak it turns hostile and
 * attacks whoever led it.
 */
@creature("npc_threshwackonator")
struct Threshwackonator
{
    enum uint questGyromastRevenge = 2078, gelkak = 6667, factionHostile = 14, textKeyReady = 758, turnKey = 1;
    enum : int { emoteStart = -1000325, sayAtClose = -1000326 }

    enum Step : ubyte { look }
    Schedule!Step steps;
    Follower follower;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questGyromastRevenge) != QuestProgress.incomplete || follower.active)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Turn the key to start the machine.", turnKey);
        me.sendGossip(e.player, textKeyReady, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != turnKey || follower.active)
            return;
        me.closeGossip(e.player);
        me.say(emoteStart);
        follower.start(me, e.player, 0);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!follower.active)
            return steps.clear();
        if (me.inCombat)
            return;
        const gelkakRef = me.creatureNearby(gelkak, 10);
        if (!gelkakRef)
            return;
        me.sayOther(gelkakRef, sayAtClose);
        me.setFaction(factionHostile);
        const holder = follower.player;
        follower.complete(me, true);
        me.attack(holder);
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (follower.completed)
            me.despawn(1000);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        follower.fail(me);
    }
}

/**
 * Volcor: escapes the Blackwood furbolgs with the player, quietly (running; at the third point he is
 * free) or fighting his way out (walking; free at the fifteenth). One path serves both.
 */
@creature("npc_volcor")
struct Volcor
{
    enum uint questThroughForce = 994, questThroughStealth = 995;
    enum uint sayAggro1 = 1250; /// to 1253 (`broadcast_text`)

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.sit);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!escort.active)
            me.standState(StandState.sit);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if ((e.quest != questThroughForce && e.quest != questThroughStealth) || escort.active)
            return;
        me.standState(StandState.stand);
        escort.start(me, e.player, e.quest, e.quest == questThroughStealth);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const line = me.random(6);
        if (line < 4)
            me.sayText(sayAggro1 + line);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        if (point + 1 == 3 && escort.quest == questThroughStealth)
        {
            me.groupQuestEvent(escort.player, questThroughStealth);
            escort.active = false;
            me.restoreNpcFlags();
            me.despawn(1000);
        }
        else if (point + 1 == 15 && escort.quest == questThroughForce)
        {
            me.groupQuestEvent(escort.player, questThroughForce);
            escort.active = false;
            me.restoreNpcFlags();
            me.despawn(60_000);
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/// Therylune: led out of the Master's Glaive (`script_waypoint` 3584).
@creature("npc_therylune")
struct Therylune
{
    enum uint questTheryluneEscape = 945;
    enum : int { sayStart = -1000905, sayFinish = -1000906 }

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.unitFlags(UnitFlag.immuneToNpc);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questTheryluneEscape || escort.active)
            return;
        me.setFaction(EscortFaction.allianceNeutralActive);
        me.unitFlags(UnitFlag.immuneToNpc, false); // on her way, the creatures may attack her
        me.say(sayStart, e.player);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point + 1 == 18)
            me.groupQuestEvent(escort.player, questTheryluneEscape);
        else if (point + 1 == 20)
        {
            me.say(sayFinish, escort.player);
            escort.run = true;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * A rabid Thistle Bear: caught in the trap (Capture Rabid Bear, from a player on "Plagued Lands"), it
 * becomes a captured bear that follows the player (the quest's credit) for three minutes, or until
 * Tharnariun Treetender takes it. In a fight, Rabies.
 */
@creature("npc_rabid_bear")
struct RabidBear
{
    enum uint questPlaguedLands = 2118, capturedBear = 11836, tharnariun = 3701;
    enum : uint { spellRabies = 3150, spellBearCaptured = 9439 }

    enum Step : ubyte { rabies, look, leave }
    Schedule!Step steps;
    bool captured;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.every(Step.rabies, (12 + me.random(7)).seconds, 15.seconds);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellBearCaptured || !e.caster.isPlayer || captured)
            return;
        captured = true;
        steps.cancel(Step.rabies);
        me.reactState(Reaction.passive);
        me.evade(); // the fight is over
        me.changeEntry(capturedBear);
        me.reactState(Reaction.aggressive);
        if (me.questStatus(e.caster, questPlaguedLands) == QuestProgress.incomplete)
        {
            me.killCredit(e.caster, capturedBear);
            me.follow(e.caster);
            steps.every(Step.look, 1.seconds);
            steps.after(Step.leave, 180.seconds);
        }
        else
            me.despawn(1000);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.rabies:
            if (!me.inCombat)
                return steps.cancel(Step.rabies);
            me.castSpell(spellRabies);
            break;
        case Step.look:
            if (me.creatureNearby(tharnariun, 10))
            {
                me.follow(EntityRef.init);
                me.despawn(1000);
                steps.clear();
            }
            break;
        case Step.leave:
            if (me.inCombat)
                return cast(void) steps.after(Step.leave, 5.seconds);
            me.despawn(1);
            steps.clear();
            break;
        }
    }
}

/**
 * The Blackwood furbolgs: a warrior in Battle Stance with Thunderclap, a totemic with Healing Wards.
 * Open-world round 2: lured by the purified food a player put by their bonfire (`event_purify_food`),
 * they come to it, eat, and are themselves again for a minute and a half.
 */
@creature("npc_blackwood_warrior", "npc_blackwood_totemic")
struct BlackwoodFurbolg
{
    enum : uint { warrior = 2168, totemic = 2169, spellBattleStance = 7165, spellThunderclap = 8078, spellHealingWard = 5605 }
    enum : uint { factionBlackwood = 35, seekPurification = 1 }
    enum : int { emoteLured = -1010027, emotePurified = -1010028 }

    enum Step : ubyte { thunderclap, healingWard, lured, purified, corruptedAgain }
    Schedule!Step steps;
    Location bowl;  /// where the food is
    bool first;     /// the one who tells of the others
    bool purifying;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != seekPurification || me.inCombat || purifying)
            return;
        // The food: five yards before the player who put it there (`GetFirstCollisionPosition`).
        import std.math : cos, sin;

        Location at;
        if (!me.locationOf(e.from, at))
            return;
        bowl = Location(at.x + 5 * cos(at.orientation), at.y + 5 * sin(at.orientation), at.z);
        first = e.value != 0;
        purifying = true;
        steps.after(Step.lured, first ? 0.msecs : me.random(5001).msecs);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (purifying && e.point == seekPurification)
            steps.after(Step.purified, 5.seconds);
    }

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (me.self.entry == warrior)
            me.castSelf(spellBattleStance);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (purifying)
            corruptedAgain(me);
        purifying = false;
        if (me.self.entry == warrior)
            me.castSelf(spellBattleStance);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (purifying)
            return;
        if (me.self.entry == warrior)
            steps.after(Step.thunderclap, (16 + me.random(6)).seconds);
        else
            steps.after(Step.healingWard, (6 + me.random(7)).seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        switch (step) // open-world round 2: the food
        {
        case Step.lured:
            if (first)
                me.say(emoteLured);
            me.reactState(Reaction.passive);
            me.unitFlags(UnitFlag.immuneToPlayer);
            me.moveTo(bowl, seekPurification, true);
            return;
        case Step.purified:
            if (first)
                me.say(emotePurified);
            me.setFaction(factionBlackwood);
            steps.after(Step.corruptedAgain, 90.seconds);
            return;
        case Step.corruptedAgain:
            corruptedAgain(me);
            purifying = false;
            me.sendHome();
            return;
        default:
            break;
        }
        if (!me.inCombat)
            return steps.clear();
        final switch (step)
        {
        case Step.lured, Step.purified, Step.corruptedAgain:
            break;
        case Step.thunderclap:
            if (me.victim && me.distanceTo(me.victim) < 5 && me.castSelf(spellThunderclap) == ActionResult.ok)
                steps.after(Step.thunderclap, (16 + me.random(6)).seconds);
            else
                steps.after(Step.thunderclap, 1.seconds);
            break;
        case Step.healingWard:
            if (me.castSelf(spellHealingWard) == ActionResult.ok)
                steps.after(Step.healingWard, (30 + me.random(7)).seconds);
            else
                steps.after(Step.healingWard, 1.seconds);
            break;
        }
    }
}

/// The food's purification over: a furbolg of the Blackwood again, aggressive.
private void corruptedAgain(ref CreatureContext me)
{
    me.setFaction(0);
    me.reactState(Reaction.aggressive);
    me.unitFlags(UnitFlag.immuneToPlayer, false);
}

/**
 * Open-world round 2: the purified food put by the Blackwood bonfire (the "Cleansing of the Infected"
 * event, 3938): two more warriors come, and the furbolgs near who are not fighting are lured to it, the
 * last one called telling of them. The event's database script goes on (Xabraxxis comes).
 */
@scriptedEvent("event_purify_food")
struct PurifyFood
{
    void on(ref EventContext e, const ref EventStarted ev)
    {
        import std.math : cos, sin, PI;

        Location fire;
        if (!ev.source.isPlayer || !ev.target.isGameObject || !e.locationOf(ev.target, fire))
            return;
        EntityRef[24] furbolgs;
        size_t count = e.creaturesNear(fire, BlackwoodFurbolg.warrior, 40, furbolgs[]);
        count += e.creaturesNear(fire, BlackwoodFurbolg.totemic, 40, furbolgs[count .. $]);
        foreach (i; 0 .. 2) // two warriors from around the fire, for two minutes out of a fight
        {
            const angle = 2 * PI * i / 2 + 0.5;
            const warrior = e.summon(BlackwoodFurbolg.warrior,
                Location(fire.x + 20 * cos(angle), fire.y + 20 * sin(angle), fire.z), 120_000);
            if (warrior && count < furbolgs.length)
                furbolgs[count++] = warrior;
        }
        foreach (i, furbolg; furbolgs[0 .. count])
            e.signal(furbolg, BlackwoodFurbolg.seekPurification, i + 1 == count);
    }
}

/// The Blackwood food stores: whoever takes from them is attacked by a warrior near, or one who comes.
@gameObject("go_furbolg_food")
struct FurbolgFood
{
    void on(ref GameObjectContext it, const ref ObjectUsed e)
    {
        const at = it.location;
        if (!it.creatureNearby(BlackwoodFurbolg.warrior, 20))
            it.summon(BlackwoodFurbolg.warrior, Location(at.x + 8, at.y + 8, at.z), 120_000, e.player);
        // A warrior standing near notices the theft on his own (he is hostile and close); the chest opens as usual.
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.darkshore;

    // Kerlonian: falls asleep, the horn wakes him, and Liladris near ends it.
    auto k = Driven!self("npc_kerlonian", 11_218);
    k.host.quests[Kerlonian.questSleeperAwakened] = QuestProgress.incomplete;
    k.raise(QuestAccepted(hero, Kerlonian.questSleeperAwakened));
    assert(k.host.has("follow") && k.host.has("faction 290") && k.host.has("say -1000434"));
    k.run(11_000);
    assert(k.host.has("cast 25148") && k.host.has("unfollow"));
    k.raise(SpellHit(hero, Kerlonian.spellAwaken));
    assert(k.host.has("say -1000445"));
    k.host.nearby[Kerlonian.liladris] = creatureRef(Kerlonian.liladris);
    k.run(1000);
    assert(k.host.has("event 5321") && k.host.has("say -1000444") && k.host.has("despawn"));

    // Lost on the way: the quest fails.
    auto lost = Driven!self("npc_kerlonian", 11_218);
    lost.host.quests[Kerlonian.questSleeperAwakened] = QuestProgress.incomplete;
    lost.raise(QuestAccepted(hero, Kerlonian.questSleeperAwakened));
    lost.host.distance = 150;
    lost.run(1100);
    assert(lost.host.has("fail 5321"));

    // Volcor's two ways out of one path.
    auto quiet = Driven!self("npc_volcor", 3692, 24);
    quiet.raise(QuestAccepted(hero, Volcor.questThroughStealth));
    quiet.walkTo(2);
    assert(quiet.host.has("event 995") && quiet.host.has("despawn"));
    auto loud = Driven!self("npc_volcor", 3692, 24);
    loud.raise(QuestAccepted(hero, Volcor.questThroughForce));
    loud.walkTo(14);
    assert(loud.host.has("event 994") && !loud.host.has("event 995"));

    // The Threshwackonator turns on its holder at Gelkak.
    auto t = Driven!self("npc_threshwackonator", 6669);
    t.host.quests[Threshwackonator.questGyromastRevenge] = QuestProgress.incomplete;
    assert(t.raise(GossipHello(hero)));
    t.raise(GossipSelect(hero, 0, 0, Threshwackonator.turnKey));
    t.host.nearby[Threshwackonator.gelkak] = creatureRef(Threshwackonator.gelkak);
    t.run(1000);
    assert(t.host.has("say as 6667 -1000326") && t.host.has("faction 14") && t.host.has("attack 6669 hero"));

    // The trapped bear: credit, following, then gone at Tharnariun's.
    auto b = Driven!self("npc_rabid_bear", 2164);
    b.host.quests[RabidBear.questPlaguedLands] = QuestProgress.incomplete;
    b.raise(SpellHit(hero, RabidBear.spellBearCaptured));
    assert(b.host.has("entry 11836") && b.host.has("credit 11836") && b.host.has("follow"));
    b.host.nearby[RabidBear.tharnariun] = creatureRef(RabidBear.tharnariun);
    b.run(1000);
    assert(b.host.has("despawn"));
}

unittest // Open-world round 2: a furbolg lured by the purified food
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.darkshore;

    auto f = Driven!self("npc_blackwood_warrior", BlackwoodFurbolg.warrior);
    f.raise(Signal(hero, BlackwoodFurbolg.seekPurification, 1));
    f.run(100);
    assert(f.host.has("say -1010027") && f.host.has("passive") && f.host.has("move 1"));
    f.raise(MovementDone(BlackwoodFurbolg.seekPurification));
    f.run(5000);
    assert(f.host.has("say -1010028") && f.host.has("faction 35"));
    f.run(90_000);
    assert(f.host.has("faction 0") && f.host.has("home"));
}

