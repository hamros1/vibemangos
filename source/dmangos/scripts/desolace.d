/**
 * Desolace: the old kodos tamed with the Kodo Kombobulator and led to Smeed Scrabblescrew ("Kodo
 * Roundup", 5561); the escorts of Dalinda Malem ("Return to Vahlarriel", 1440) and Melizza
 * Brimbuzzle out of the Maraudine camp ("Get Me Out of Here!", 6132); and the Magram spectres.
 */
module dmangos.scripts.desolace;

import dmangos.script;

/**
 * An aged, dying or ancient kodo: the Kodo Kombobulator tames it, and it follows the player; at
 * Smeed's it stops, and the player talking to it there is the quest's credit. A minute later it goes.
 */
@creature("npc_aged_dying_ancient_kodo")
struct AgedDyingAncientKodo
{
    enum uint questKodoRoundup = 5561, smeed = 11596, tamedKodo = 11627, gossipFlag = 1;
    enum : uint { spellKombobulator = 18153, spellKomboPlayerBuff = 18172, spellKomboDespawnBuff = 18377 }
    enum int saySmeedHome1 = -1000348; /// to -1000350, said by Smeed

    enum Step : ubyte { look, leave }
    Schedule!Step steps;
    EntityRef tamer;
    bool home, talked;

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellKombobulator || !e.caster.isPlayer || tamer)
            return;
        tamer = e.caster;
        me.castSpell(spellKomboPlayerBuff, e.caster, true);
        me.updateEntry(tamedKodo);
        me.castSelf(spellKomboDespawnBuff, true);
        me.follow(e.caster);
        steps.every(Step.look, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.look:
            if (home || me.inCombat)
                break;
            if (const smeedRef = me.creatureNearby(smeed, 10))
            {
                home = true;
                me.sayFrom(smeedRef, saySmeedHome1 - cast(int) me.random(3));
                me.follow(EntityRef.init);
                me.npcFlags(gossipFlag);
                steps.cancel(Step.look);
                steps.after(Step.leave, 60.seconds);
            }
            break;
        case Step.leave:
            if (me.inCombat)
                return cast(void) steps.after(Step.leave, 5.seconds);
            me.despawn(1); // back as a wild kodo
            break;
        }
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!home || talked || e.player != tamer)
            return;
        talked = true;
        me.killCredit(e.player, tamedKodo); // the quest's "talk to" objective
        me.removeAura(e.player, spellKomboPlayerBuff);
        steps.after(Step.leave, 10.seconds);
    }
}

/// Dalinda Malem: led out of Thunder Axe Fortress (`script_waypoint` 5644).
@creature("npc_dalinda_malem")
struct DalindaMalem
{
    enum uint questReturnToVahlarriel = 1440;

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.kneel);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questReturnToVahlarriel || escort.active)
            return;
        me.setFaction(EscortFaction.allianceNeutralPassive);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        me.standState(StandState.stand);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (escort.reached(me, e) + 1 == 18)
            me.groupQuestEvent(escort.player, questReturnToVahlarriel);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/**
 * Melizza Brimbuzzle: out of her cage and through the Maraudine, who come after her twice; free at
 * the twelfth point (the quest), she runs on and tells of it at the end of her path, Hornizz
 * answering.
 */
@creature("npc_melizza_brimbuzzle")
struct MelizzaBrimbuzzle
{
    enum uint questGetMeOut = 6132, cage = 177706, hornizz = 6019;
    enum : uint { maraudineMarauder = 4659, maraudineBonepaw = 4660, maraudineWrangler = 4655 }
    enum : int
    {
        sayStart = -1000784, sayFinish = -1000785, say1 = -1000786, say2 = -1000787, say3 = -1000788,
        sayHornizz1 = -1010030, sayHornizz2 = -1010031,
    }

    private static immutable Location[2] marauderAt = [Location(-1291.492f, 2644.650f, 111.556f),
        Location(-1306.730f, 2675.163f, 111.561f)];
    private static immutable wranglerAt = Location(-1393.194f, 2429.465f, 88.689f);

    enum Step : ubyte { free, say1, say2, say3, onward, hornizz1, hornizz2 }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questGetMeOut || escort.active)
            return;
        escort.start(me, e.player, e.quest);
        if (const cageRef = me.objectNearby(cage, 5))
            me.useObject(cageRef);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 1:
            me.say(sayStart, escort.player);
            me.setFaction(EscortFaction.neutralNeutralPassive);
            break;
        case 4:
            foreach (at; marauderAt)
                foreach (_; 0 .. 2)
                    me.attackBy(me.summon(maraudineMarauder, near(me, at, 7)), me.self);
            break;
        case 9:
            foreach (_; 0 .. 3)
            {
                me.attackBy(me.summon(maraudineBonepaw, near(me, wranglerAt, 10)), me.self);
                me.attackBy(me.summon(maraudineWrangler, near(me, wranglerAt, 10)), me.self);
            }
            break;
        case 12:
            escort.pause(true);
            steps.after(Step.free, 1.seconds);
            break;
        case 19:
            escort.pause(true);
            steps.after(Step.say1, 2.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.free:
            me.say(sayFinish, escort.player);
            me.groupQuestEvent(escort.player, questGetMeOut);
            me.restoreFaction();
            escort.run = true;
            escort.pause(false);
            break;
        case Step.say1:
            me.say(say1);
            steps.after(Step.say2, 4.seconds);
            break;
        case Step.say2:
            me.say(say2);
            steps.after(Step.say3, 5.seconds);
            break;
        case Step.say3:
            me.say(say3);
            steps.after(Step.onward, 4.seconds);
            break;
        case Step.onward:
            escort.pause(false);
            steps.after(Step.hornizz1, 6.seconds);
            break;
        case Step.hornizz1:
            if (const h = me.creatureNearby(hornizz, 100))
                me.sayFrom(h, sayHornizz1);
            steps.after(Step.hornizz2, 10.seconds);
            break;
        case Step.hornizz2:
            if (const h = me.creatureNearby(hornizz, 100))
                me.sayFrom(h, sayHornizz2);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }

    private static Location near(ref CreatureContext me, Location at, int radius)
    {
        const span = 2 * radius + 1;
        return Location(at.x + (cast(int) me.random(span) - radius), at.y + (cast(int) me.random(span) - radius), at.z);
    }
}

/// A Magram spectre: rises with its glow and a moan; in a fight, the Curse of Magrami once.
@creature("npc_magrami_spectre")
struct MagramiSpectre
{
    enum : uint { spellCurse = 18159, spellGhostSpawnIn = 17321, spellBlueAura = 17327, spellGreenAura = 18951,
        spellChillingTouch = 18146, factionHostile = 16 }
    enum int sayEmote1 = -1001226;

    enum Step : ubyte { curse }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(spellGhostSpawnIn);
        me.castSelf(spellBlueAura);
        me.castSelf(spellChillingTouch);
        me.say(sayEmote1 - cast(int) me.random(2));
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.curse, 4.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            me.castSpell(spellCurse);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point != 1)
            return;
        me.removeAura(me.self, spellBlueAura);
        me.castSelf(spellGreenAura);
        me.setFaction(factionHostile);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.desolace;

    // A kodo tamed, led to Smeed, talked to: the credit, and it goes.
    auto k = Driven!self("npc_aged_dying_ancient_kodo", 4700);
    k.raise(SpellHit(hero, AgedDyingAncientKodo.spellKombobulator));
    assert(k.host.has("entry 11627") && k.host.has("follow"));
    k.raise(GossipHello(hero));
    assert(!k.host.has("credit 11627"), "not before Smeed's");
    k.host.nearby[AgedDyingAncientKodo.smeed] = creatureRef(AgedDyingAncientKodo.smeed);
    k.run(1000);
    assert(k.host.has("npcflags 1") && k.host.has("unfollow"));
    k.raise(GossipHello(hero));
    assert(k.host.has("credit 11627"));
    k.run(10_000);
    assert(k.host.has("despawn"));

    // Melizza: out of the cage, ambushed, free at twelve; the tale at nineteen.
    auto m = Driven!self("npc_melizza_brimbuzzle", 12_277, 24);
    m.host.objects[MelizzaBrimbuzzle.cage] = EntityRef(0xF110_0000_0000_0002);
    m.raise(QuestAccepted(hero, MelizzaBrimbuzzle.questGetMeOut));
    m.walkTo(11);
    assert(m.host.summons == 10 && m.host.has("faction 113"));
    m.run(1000);
    assert(m.host.has("event 6132") && m.host.has("faction 0"));
    m.run(100);
    m.walkTo(18);
    m.run(15_200);
    assert(m.host.has("say -1000788") && m.host.has("move 19"));
}
