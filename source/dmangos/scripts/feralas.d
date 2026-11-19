/**
 * Feralas: the escort of the homing robot OOX-22/FE ("Rescue OOX-22/FE!", 2767); Shay Leafrunner,
 * who wanders off until her bell calls her back, on her way to Rockbiter ("Wandering Shay", 2845);
 * and Kindal Moonweaver's "Freedom for All Creatures" (2969): the sprite darters let out of their
 * cages fly home, and with six of them free the quest is done.
 */
module dmangos.scripts.feralas;

import dmangos.script;

/// OOX-22/FE: switched on, it walks home to Gadgetzan's way; yetis, gorillas and gnolls ambush it.
@creature("npc_oox22fe")
struct Oox22fe
{
    enum uint questRescueOox22fe = 2767;
    enum : uint { yeti = 7848, gorilla = 5260, woodpawReaver = 5255, woodpawBrute = 5253, woodpawAlpha = 5258,
        woodpawMystic = 5254 }
    enum : int { sayStart = -1000287, sayAggro1 = -1000288, sayAggro2 = -1000289, sayAmbush = -1000290, sayEnd = -1000292 }

    Escort escort = { despawnAfterMs: 1000 };
    EntityRef[4] ambush;

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
        if (e.quest != questRescueOox22fe || escort.active)
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
        case 12:
            me.say(sayAmbush);
            send(me, [yeti, yeti, yeti], [Location(-4841.01f, 1593.91f, 73.42f, 3.98f),
                Location(-4837.61f, 1568.58f, 78.21f, 3.13f), Location(-4841.89f, 1569.95f, 76.53f, 0.68f)]);
            break;
        case 22:
            me.say(sayAmbush);
            send(me, [gorilla, gorilla, gorilla], [Location(-4595.81f, 2005.99f, 53.08f, 3.74f),
                Location(-4597.53f, 2008.31f, 52.70f, 3.78f), Location(-4599.37f, 2010.59f, 52.77f, 3.84f)]);
            break;
        case 31:
            me.say(sayAmbush);
            send(me, [woodpawReaver, woodpawBrute, woodpawMystic, woodpawAlpha], [Location(-4425.14f, 2075.87f, 47.77f, 3.77f),
                Location(-4426.68f, 2077.98f, 47.57f, 3.77f), Location(-4428.33f, 2080.24f, 47.43f, 3.87f),
                Location(-4430.04f, 2075.54f, 46.83f, 3.81f)]);
            break;
        case 38:
            me.say(sayEnd);
            me.groupQuestEvent(escort.player, questRescueOox22fe);
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

    private void send(ref CreatureContext me, const uint[] entries, const Location[] at)
    {
        ambush[] = EntityRef.init;
        foreach (i, entry; entries)
        {
            ambush[i] = me.summon(entry, at[i], 10_000);
            me.attack(ambush[i], me.self);
        }
    }
}

/**
 * Shay Leafrunner: follows the player to Rockbiter, but wanders off now and then; Shay's Bell brings
 * her back. Near Rockbiter, the quest is done.
 */
@creature("npc_shay_leafrunner")
struct ShayLeafrunner
{
    enum uint questWanderingShay = 2845, rockbiter = 7765, spellShaysBell = 11402;
    enum : int
    {
        sayEscortStart = -1001106, sayWander1 = -1001107, sayWanderDone1 = -1001111, emoteWander = -1001114,
        sayComplete1 = -1001115, sayComplete2 = -1001116,
    }

    enum Step : ubyte { wander, look }
    Schedule!Step steps;
    Follower follower;
    bool wandering;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questWanderingShay || follower.active)
            return;
        me.say(sayEscortStart);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        follower.start(me, e.player, e.quest);
        wandering = false;
        steps.after(Step.wander, 30.seconds);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellShaysBell || !e.caster.isPlayer || !follower.active || !wandering)
            return;
        wandering = false;
        follower.pause(me, false);
        me.say(sayWanderDone1 - cast(int) me.random(3));
        steps.after(Step.wander, 60.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!follower.active)
            return steps.clear();
        final switch (step)
        {
        case Step.wander:
            if (me.inCombat)
                return cast(void) steps.after(Step.wander, 5.seconds);
            wandering = true;
            follower.pause(me, true);
            me.say(emoteWander);
            me.say(sayWander1 - cast(int) me.random(4));
            const at = me.location;
            const angle = me.random(628) / 100.0f, distance = 25 + me.random(16);
            import std.math : cos, sin;

            me.moveTo(Location(at.x + distance * cos(angle), at.y + distance * sin(angle), at.z), 1);
            break;
        case Step.look:
            if (me.inCombat)
                break;
            const r = me.creatureNearby(rockbiter, 20);
            if (!r)
                break;
            me.say(sayComplete1);
            me.sayOther(r, sayComplete2);
            me.groupQuestEvent(follower.player, questWanderingShay);
            follower.complete(me, true);
            Location there;
            if (me.locationOf(r, there))
                me.moveTo(Location(there.x + 2, there.y, there.z), 2);
            me.despawn(30_000);
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

/// Signals of "Freedom for All Creatures".
private enum Freedom : uint { cageOpened = 1, flee = 2, freed = 3, raider = 4 }

/// A captured sprite darter: its cage opened, it flies off along its path and is free at its end.
@creature("npc_captured_sprite_darter")
struct CapturedSpriteDarter
{
    enum uint manaBurn = 11981;

    enum Step : ubyte { manaBurn }
    Schedule!Step steps;
    Escort escort;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Freedom.flee || escort.active)
            return;
        me.setFaction(EscortFaction.neutralFriendActive);
        escort.maxDistance = float.infinity;
        escort.start(me, me.self, 0, true); // on its own: no player to stay near
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point != uint.max && point + 1 == me.waypointCount)
        {
            if (const kindal = me.creatureNearby(KindalMoonweaver.kindal, 200))
                me.signal(kindal, Freedom.freed);
            escort.active = false;
            me.despawn(1);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.manaBurn, (3 + me.random(4)).seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return;
        if (const target = me.randomTarget())
            if (me.castSpell(manaBurn, target) == ActionResult.ok)
                return cast(void) steps.after(Step.manaBurn, (7 + me.random(4)).seconds);
        steps.after(Step.manaBurn, 2.seconds);
    }
}

/// A cage of the Grimtotem: opened, the sprite darters near fly free, and a Grimtotem raider comes.
@gameObject("go_cage_door")
struct GrimtotemCageDoor
{
    enum uint spriteDarter = 7997, grimtotemRaider = 7725;

    void on(ref GameObjectContext it, const ref ObjectUsed e)
    {
        const kindal = it.creatureNearby(KindalMoonweaver.kindal, 40);
        if (kindal)
            it.signal(kindal, Freedom.cageOpened);
        EntityRef[8] darters;
        foreach (d; darters[0 .. it.creaturesNearby(spriteDarter, 20, darters[])])
            it.signal(d, Freedom.flee);
        if (it.summon(grimtotemRaider, Location(-4515.35f, 811.36f, 62.99f, 3.60244f), 600_000, e.player) && kindal)
            it.signal(kindal, Freedom.raider);
    }
}

/**
 * Kindal Moonweaver: follows the player while the cages are opened, shooting at the Grimtotem; with
 * six sprite darters free, the quest is done, and she goes home.
 */
@creature("npc_kindal_moonweaver")
struct KindalMoonweaver
{
    enum uint kindal = 7956, questFreedom = 2969, grimtotemRaider = 7725;
    enum : uint { spellShoot = 14443, spellMultiShot = 6660 }
    enum : int { sayQuestStart = -1010023, sayInitialAggro = -1010024, sayAggro = -1010025, sayQuestComplete = -1010026 }

    enum Step : ubyte { shoot, multiShot, leave }
    Schedule!Step steps;
    Follower follower;
    ubyte freed;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questFreedom || follower.active)
            return;
        follower.start(me, e.player, e.quest, EscortFaction.allianceNeutralActive);
        me.say(sayQuestStart);
        me.standState(StandState.stand);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        freed = 0;
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (!follower.active)
            return;
        switch (e.id)
        {
        case Freedom.cageOpened:
            freed = 0;
            break;
        case Freedom.raider:
            if (const raider = me.creatureNearby(grimtotemRaider, 80))
            {
                me.say(sayInitialAggro, raider);
                me.attack(raider);
            }
            break;
        case Freedom.freed:
            if (++freed < 6)
                break;
            if (me.questStatus(follower.player, questFreedom) == QuestProgress.incomplete)
                me.groupQuestEvent(follower.player, questFreedom);
            me.say(sayQuestComplete, follower.player);
            follower.complete(me, true);
            steps.after(Step.leave, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (me.random(4) == 0)
            me.say(sayAggro, e.enemy);
        steps.after(Step.shoot, (2 + me.random(3)).seconds);
        steps.after(Step.multiShot, (8 + me.random(4)).seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shoot:
            if (me.inCombat)
                steps.after(Step.shoot, ranged(me, spellShoot) ? (2 + me.random(3)).seconds : 1.seconds);
            break;
        case Step.multiShot:
            if (me.inCombat)
                steps.after(Step.multiShot, ranged(me, spellMultiShot) ? (8 + me.random(4)).seconds : 1.seconds);
            break;
        case Step.leave:
            me.unitFlags(UnitFlag.immuneToNpc);
            me.despawn(1);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        follower.fail(me);
        steps.clear();
    }

    private bool ranged(ref CreatureContext me, uint spell)
    {
        const d = me.distanceTo(me.victim);
        return d >= 5 && d <= 30 && me.castSpell(spell) == ActionResult.ok;
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.feralas;

    // OOX-22/FE: three ambushes, home.
    auto o = Driven!self("npc_oox22fe", 7807, 38);
    o.raise(QuestAccepted(hero, Oox22fe.questRescueOox22fe));
    o.walkTo(37);
    assert(o.host.summons == 10 && o.host.has("event 2767") && o.host.has("attack 5258 7807"));

    // Shay: wanders off, the bell brings her back, Rockbiter ends it.
    auto s = Driven!self("npc_shay_leafrunner", 7774);
    s.raise(QuestAccepted(hero, ShayLeafrunner.questWanderingShay));
    s.run(30_000);
    assert(s.host.has("say -1001114") && s.host.has("unfollow"));
    s.raise(SpellHit(hero, ShayLeafrunner.spellShaysBell));
    assert(s.host.has("say -1001111"));
    s.host.nearby[ShayLeafrunner.rockbiter] = creatureRef(ShayLeafrunner.rockbiter);
    s.run(1000);
    assert(s.host.has("event 2845") && s.host.has("say as 7765 -1001116"));

    // Kindal: six darters free.
    auto k = Driven!self("npc_kindal_moonweaver", 7956);
    k.raise(QuestAccepted(hero, KindalMoonweaver.questFreedom));
    k.host.quests[KindalMoonweaver.questFreedom] = QuestProgress.incomplete;
    foreach (i; 0 .. 6)
    {
        assert(!k.host.has("event 2969"));
        k.raise(Signal(creatureRef(7997, i), Freedom.freed));
    }
    assert(k.host.has("event 2969") && k.host.has("say -1010026"));

    // A darter flies its path and tells Kindal.
    auto d = Driven!self("npc_captured_sprite_darter", 7997, 8);
    d.host.nearby[KindalMoonweaver.kindal] = creatureRef(KindalMoonweaver.kindal);
    d.raise(Signal(EntityRef(0xF110_0000_0000_0005), Freedom.flee));
    d.walkTo(7);
    assert(d.host.has("signal 3") && d.host.has("despawn"));

    // The cage: the darters near are told, a raider comes.
    auto cage = new RecordingObject(143_979);
    cage.nearby[7997] = creatureRef(7997);
    cage.nearby[KindalMoonweaver.kindal] = creatureRef(KindalMoonweaver.kindal);
    use!self("go_cage_door", cage);
    assert(cage.has("signal 7997 2") && cage.has("summon 7725") && cage.has("signal 7956 4"));
}
