/**
 * Moonglade: "Nightmare Manifests" (8736). Keeper Remulos leads the player to the lake shore and
 * conjures a rift; Eranikus, Tyrant of the Dream, comes out of it and sends the Nightmare's
 * phantasms at Nighthaven, the Nighthaven defenders against them; then he lands and fights. Worn
 * down, Tyrande Whisperwind and the priestesses of Elune come, and at a fifth of his health he is
 * redeemed: the quest is done.
 */
module dmangos.scripts.moonglade;

import dmangos.script;

/// Signals between Remulos and Eranikus.
private enum Nightmare : uint { stopWaves = 1, redeemed = 2, remulosFell = 3 }

/// Creatures and places of the event.
private enum : uint
{
    remulos = 11832,
    eranikusTyrant = 15491,
    eranikusRedeemed = 15628,
    nightmarePhantasm = 15629,
    tyrande = 15633,
    elunePriestess = 15634,
    nighthavenDefender = 15495,
}

private static immutable Location[4] eranikusAt = [
    Location(7881.72f, -2651.23f, 493.29f, 0.40f), // where he comes
    Location(7929.86f, -2574.88f, 505.35f),        // over the village
    Location(7912.98f, -2568.99f, 488.71f),        // where he lands to fight
    Location(7906.57f, -2565.63f, 488.39f),        // redeemed
];
private static immutable Location[3] tyrandeAt = [
    Location(7948.89f, -2575.58f, 490.05f, 3.03f), // where she comes
    Location(7888.32f, -2566.25f, 487.02f),        // where she heals
    Location(7901.83f, -2565.24f, 488.04f),        // before Eranikus
];

/**
 * Keeper Remulos: leads the player to the shore, talks with Eranikus, and holds Nighthaven against
 * the phantasms, wave after wave, with the defenders; Healing Touch, Rejuvenation, Regrowth and
 * Starfire in a fight.
 */
@creature("npc_keeper_remulos")
struct KeeperRemulos
{
    enum uint questNightmareManifests = 8736, factionCenarionCircle = 996, maxShadows = 3, maxDefenders = 10,
        maxWaves = 10, pvpFlag = 0x1000;
    enum : uint { spellHealingTouch = 23381, spellRegrowth = 20665, spellRejuvenation = 20664, spellStarfire = 21668,
        spellDragonHover = 18430 }
    enum : int
    {
        sayIntro1 = -1000669, sayIntro2 = -1000670, sayIntro3 = -1000671, sayIntro4 = -1000672, sayIntro5 = -1000673,
        emoteSummonEranikus = -1000674, sayEranikusSpawn = -1000675, sayTaunt1 = -1000676, emoteEranikusLaugh = -1000677,
        sayEranikusTaunt2 = -1000678, sayTaunt3 = -1000679, sayEranikusTaunt4 = -1000680, emoteEranikusAttack = -1000681,
        sayDefend1 = -1000682, sayDefend2 = -1000683, sayEranikusShadows = -1000684, sayDefend3 = -1000685,
        sayEranikusAttack1 = -1000686, sayOutro1 = -1000704, sayOutro2 = -1000705,
    }

    /// What a line of the scene does besides being said.
    enum Act : ubyte { none, intro3, conjure, eranikusComes, flyOff, faceEranikus, holdTheVillage }
    /// A line: who says it (Remulos, or Eranikus), what it does, and the next after `delayMs` (0: the scene waits).
    static struct Line
    {
        int text;
        bool byEranikus;
        Act act;
        uint delayMs;
    }

    private static immutable Line[] scene = [
        Line(0, false, Act.intro3, 14_000),
        Line(sayIntro4, false, Act.none, 12_000),
        Line(sayIntro5, false, Act.none, 5000),
        Line(0, false, Act.conjure, 13_000),
        Line(sayEranikusSpawn, true, Act.eranikusComes, 11_000),
        Line(sayTaunt1, false, Act.none, 5000),
        Line(emoteEranikusLaugh, true, Act.none, 3000),
        Line(sayEranikusTaunt2, true, Act.none, 10_000),
        Line(sayTaunt3, false, Act.none, 12_000),
        Line(sayEranikusTaunt4, true, Act.none, 6000),
        Line(emoteEranikusAttack, true, Act.none, 7000),
        Line(0, false, Act.flyOff, 0),                         // 11: on to the village
        Line(sayDefend2, false, Act.faceEranikus, 6000),       // 12: at the village
        Line(sayEranikusShadows, true, Act.none, 4000),
        Line(sayDefend3, false, Act.holdTheVillage, 0),
    ];
    enum size_t atTheVillage = 12;

    private static immutable Location[6] shadowsAt = [
        Location(7832.78f, -2604.57f, 489.29f), Location(7826.68f, -2538.46f, 489.30f), Location(7811.48f, -2573.20f, 488.49f),
        Location(7888.32f, -2566.25f, 487.02f), Location(7946.12f, -2577.10f, 489.97f), Location(7963.00f, -2492.03f, 487.84f),
    ];
    private static immutable Location[2] defendersAt = [Location(7868.226f, -2556.95f, 487.07f),
        Location(7867.39f, -2578.96f, 486.95f)];

    enum Step : ubyte { line, wave, heal, starfire, outro }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    size_t next;
    ubyte waves, outro;
    bool firstWave;
    EntityRef eranikus;
    EntityRef[maxDefenders] defenders;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questNightmareManifests || escort.active)
            return;
        next = waves = outro = 0;
        firstWave = true;
        eranikus = EntityRef.init;
        defenders[] = EntityRef.init;
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
            me.say(sayIntro1, escort.player);
            me.unitFlags(pvpFlag); // friendly players' spells may reach him now
            break;
        case 2:
            me.say(sayIntro2);
            break;
        case 14:
            escort.pause(true);
            next = 0;
            steps.after(Step.line, 1.msecs);
            break;
        case 18:
            escort.pause(true);
            next = atTheVillage;
            steps.after(Step.line, 1.msecs);
            break;
        case 19:
            escort.pause(true);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.line:
            if (next >= scene.length)
                return;
            const line = scene[next++];
            if (line.text)
            {
                if (line.byEranikus)
                    me.sayFrom(eranikus, line.text);
                else
                    me.say(line.text);
            }
            act(me, line.act);
            if (line.delayMs)
                steps.after(Step.line, line.delayMs.msecs);
            break;
        case Step.wave:
            wave(me);
            break;
        case Step.heal:
            if (!me.inCombat)
                return;
            static immutable uint[3] heals = [spellHealingTouch, spellRejuvenation, spellRegrowth];
            me.castSelf(heals[me.random(3)]);
            steps.after(Step.heal, 10.seconds);
            break;
        case Step.starfire:
            if (!me.inCombat)
                return;
            const target = me.randomTarget();
            steps.after(Step.starfire, target && me.castSpell(spellStarfire, target) == ActionResult.ok ? 20.seconds : 2.seconds);
            break;
        case Step.outro:
            if (outro++ == 0)
            {
                me.say(sayOutro1);
                steps.after(Step.outro, 3.seconds);
            }
            else
            {
                me.say(sayOutro2);
                escort.active = false;
                me.despawn(3000);
            }
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.heal, 10.seconds);
        steps.after(Step.starfire, 25.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.from != eranikus)
            return;
        if (e.id == Nightmare.stopWaves)
            steps.cancel(Step.wave);
        else if (e.id == Nightmare.redeemed && escort.active)
        {
            me.groupQuestEvent(escort.player, questNightmareManifests);
            foreach (d; defenders)
                if (d && me.alive(d))
                    me.despawn(d);
            me.unitFlags(pvpFlag, false);
            steps.after(Step.outro, 3.seconds);
        }
    }

    void on(ref CreatureContext me, const ref SummonDied e)
    {
        foreach (ref d; defenders)
            if (d == e.summon)
                d = EntityRef.init;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        if (eranikus)
            me.signal(eranikus, Nightmare.remulosFell);
        me.unitFlags(pvpFlag, false);
        escort.fail(me);
        steps.clear();
    }

    private void act(ref CreatureContext me, Act what)
    {
        final switch (what)
        {
        case Act.none:
            break;
        case Act.intro3:
            me.say(sayIntro3, escort.player);
            break;
        case Act.conjure:
            // The Conjure Dream Rift: Eranikus comes, hovering.
            eranikus = me.summon(eranikusTyrant, eranikusAt[0]);
            me.unitFlagsOf(eranikus, UnitFlag.immuneToNpc | UnitFlag.immuneToPlayer);
            me.castAs(eranikus, spellDragonHover, eranikus, true);
            break;
        case Act.eranikusComes:
            me.sayFrom(eranikus, emoteSummonEranikus);
            break;
        case Act.flyOff:
            me.say(sayDefend1, escort.player);
            me.removeAura(eranikus, spellDragonHover);
            me.moveOther(eranikus, eranikusAt[1], 1, true);
            escort.pause(false);
            break;
        case Act.faceEranikus:
            me.face(eranikus);
            break;
        case Act.holdTheVillage:
            escort.pause(true);
            me.setFaction(factionCenarionCircle);
            steps.after(Step.wave, 5.seconds);
            break;
        }
    }

    /// A wave of phantasms (the first also inside the houses), and defenders for the fallen.
    private void wave(ref CreatureContext me)
    {
        if (firstWave)
        {
            firstWave = false;
            foreach (at; shadowsAt[0 .. maxShadows])
                phantasm(me, at);
            me.sayFrom(eranikus, sayEranikusAttack1);
        }
        if (waves < maxWaves)
        {
            const spot = me.random(10) < 7 ? maxShadows : maxShadows + 1 + me.random(2);
            foreach (_; 0 .. maxShadows)
                phantasm(me, near(me, shadowsAt[spot], 10));
            foreach (i, ref d; defenders)
                if (!d || !me.alive(d))
                    d = me.summon(nighthavenDefender, near(me, defendersAt[i % 2], 3), 3 * 60_000);
            ++waves;
        }
        if (waves >= maxWaves)
            me.moveOther(eranikus, eranikusAt[2], 2); // he lands, to fight
        else
            steps.after(Step.wave, (20 + me.random(11)).seconds);
    }

    private void phantasm(ref CreatureContext me, Location at)
    {
        const p = me.summon(nightmarePhantasm, at, 3 * 60_000);
        me.setFactionOf(p, 14);
        me.attackBy(p, me.self);
        // A defender takes it on.
        foreach (d; defenders)
            if (d && me.alive(d) && me.attackBy(d, p) == ActionResult.ok)
                break;
    }

    private static Location near(ref CreatureContext me, Location at, int radius)
    {
        const span = 2 * radius + 1;
        return Location(at.x + (cast(int) me.random(span) - radius), at.y + (cast(int) me.random(span) - radius), at.z);
    }
}

/**
 * Eranikus, Tyrant of the Dream: over the village until the phantasms are spent, then he lands and
 * fights (Acid Breath, Noxious Breath, Shadow Bolt Volley), not moving from his place. Worn down,
 * Tyrande comes, then the priestesses; at a fifth of his health he is redeemed and the fight ends.
 */
@creature("boss_eranikus")
struct Eranikus
{
    enum : uint { spellAcidBreath = 24839, spellNoxiousBreath = 24818, spellShadowboltVolley = 25586,
        spellArcaneChanneling = 23017, spellDragonHover = 18430, spellEranikusRedeemed = 25846, maxPriestesses = 7 }
    enum : int
    {
        sayAttack2 = -1000687, sayAttack3 = -1000688, sayKill = -1000706, sayTyrandeAppear = -1000689,
        sayTyrandeHeal = -1000690, sayTyrandeForgiven1 = -1000691, sayTyrandeForgiven2 = -1000692,
        sayTyrandeForgiven3 = -1000693, sayDefeat1 = -1000694, sayDefeat2 = -1000695, sayDefeat3 = -1000696,
        emoteRedeem = -1000697, emoteTyrandeKneel = -1000698, sayTyrandeRedeemed = -1000699, sayRedeemed1 = -1000700,
        sayRedeemed2 = -1000701, sayRedeemed3 = -1000702, sayRedeemed4 = -1000703,
    }
    enum uint pointLand = 2, pointRedeemed = 3, emoteLand = 293;

    enum Step : ubyte { acidBreath, noxiousBreath, volley, tyrandeHeals, tyrandeForgives, redeem }
    Schedule!Step steps;
    ubyte nextCheck = 85, redemption;
    bool redeemed;
    EntityRef tyrandeRef, remulosRef;
    EntityRef[maxPriestesses] priestesses;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        me.preventDeath(true); // he is redeemed, not killed
        remulosRef = me.owner;
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == pointLand)
        {
            me.unitFlags(UnitFlag.immuneToNpc | UnitFlag.immuneToPlayer, false);
            me.say(sayAttack2);
            me.removeAura(me.self, spellDragonHover);
            me.emote(emoteLand);
            if (remulosRef)
                me.attack(remulosRef);
        }
        else if (e.point == pointRedeemed)
        {
            me.say(sayRedeemed1);
            steps.after(Step.redeem, 11.seconds);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (redeemed)
            return;
        steps.after(Step.acidBreath, 10.seconds);
        steps.after(Step.noxiousBreath, 3.seconds);
        steps.after(Step.volley, 5.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.say(sayKill);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Nightmare.remulosFell && !redeemed)
            leave(me);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (!redeemed)
            leave(me);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        while (!redeemed && nextCheck && e.after < nextCheck)
            check(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.acidBreath:
            if (me.inCombat && !redeemed)
                steps.after(step, me.castSelf(spellAcidBreath) == ActionResult.ok ? 15.seconds : 1.seconds);
            break;
        case Step.noxiousBreath:
            if (me.inCombat && !redeemed)
                steps.after(step, me.castSelf(spellNoxiousBreath) == ActionResult.ok ? 30.seconds : 1.seconds);
            break;
        case Step.volley:
            if (me.inCombat && !redeemed)
                steps.after(step, me.castSelf(spellShadowboltVolley) == ActionResult.ok ? 25.seconds : 1.seconds);
            break;
        case Step.tyrandeHeals:
            me.sayFrom(tyrandeRef, sayTyrandeHeal);
            me.moveOther(tyrandeRef, tyrandeAt[2], 1, true);
            steps.after(Step.tyrandeForgives, 4.seconds);
            break;
        case Step.tyrandeForgives:
            me.castAs(tyrandeRef, spellArcaneChanneling, tyrandeRef);
            me.sayFrom(tyrandeRef, sayTyrandeForgiven1);
            break;
        case Step.redeem:
            redemptionStep(me);
            break;
        }
    }

    /// The fight's turns, as his health falls.
    private void check(ref CreatureContext me)
    {
        switch (nextCheck)
        {
        case 85:
            me.say(sayAttack3);
            me.sayFrom(me.summon(tyrande, tyrandeAt[0], 1000), sayTyrandeAppear);
            nextCheck = 75;
            break;
        case 75:
            me.say(sayAttack3);
            nextCheck = 50;
            break;
        case 50:
            tyrandeRef = me.summon(tyrande, tyrandeAt[0]);
            me.moveOther(tyrandeRef, tyrandeAt[1], 0, true);
            steps.after(Step.tyrandeHeals, 8.seconds);
            nextCheck = 35;
            break;
        case 35:
            foreach (ref p; priestesses)
            {
                const at = tyrandeAt[0];
                p = me.summon(elunePriestess, Location(at.x + (cast(int) me.random(21) - 10), at.y + (cast(int) me.random(21) - 10), at.z));
                me.attackBy(p, me.self); // in the fight, to heal
            }
            me.say(sayDefeat1);
            nextCheck = 31;
            break;
        case 31:
            me.sayFrom(tyrandeRef, sayTyrandeForgiven2);
            nextCheck = 27;
            break;
        case 27:
            me.sayFrom(tyrandeRef, sayTyrandeForgiven3);
            nextCheck = 25;
            break;
        case 25:
            me.say(sayDefeat2);
            nextCheck = 20;
            break;
        case 20:
            me.say(sayDefeat3);
            nextCheck = 0;
            redeem(me);
            break;
        default:
            nextCheck = 0;
            break;
        }
    }

    private void redeem(ref CreatureContext me)
    {
        redeemed = true;
        steps.clear();
        if (remulosRef)
            me.signal(remulosRef, Nightmare.stopWaves);
        foreach (p; priestesses)
            if (p && me.alive(p))
                me.despawn(p);
        me.passive(true); // the fight is over
        me.updateEntry(eranikusRedeemed);
        redemption = 0;
        steps.after(Step.redeem, 5.seconds);
    }

    private void redemptionStep(ref CreatureContext me)
    {
        switch (redemption++)
        {
        case 0:
            me.sayFrom(tyrandeRef, emoteTyrandeKneel);
            me.say(emoteRedeem);
            me.standState(StandState.dead);
            steps.after(Step.redeem, 5.seconds);
            break;
        case 1:
            me.sayFrom(tyrandeRef, sayTyrandeRedeemed);
            steps.after(Step.redeem, 6.seconds);
            break;
        case 2:
            me.castSelf(spellEranikusRedeemed);
            steps.after(Step.redeem, 5.seconds);
            break;
        case 3:
            me.standState(StandState.stand);
            me.moveTo(eranikusAt[3], pointRedeemed);
            break;
        case 4:
            me.say(sayRedeemed2);
            steps.after(Step.redeem, 11.seconds);
            break;
        case 5:
            me.say(sayRedeemed3);
            steps.after(Step.redeem, 13.seconds);
            break;
        case 6:
            me.say(sayRedeemed4);
            steps.after(Step.redeem, 7.seconds);
            break;
        default:
            if (tyrandeRef)
                me.despawn(tyrandeRef, 9000);
            if (remulosRef)
                me.signal(remulosRef, Nightmare.redeemed);
            me.emote(2); // bow
            me.despawn(2000);
            break;
        }
    }

    /// The event failed: he and his helpers go.
    private void leave(ref CreatureContext me)
    {
        foreach (p; priestesses)
            if (p && me.alive(p))
                me.despawn(p);
        if (tyrandeRef)
            me.despawn(tyrandeRef);
        steps.clear();
        me.despawn(1);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.moonglade;

    // Remulos: the shore scene, the village, the waves; Eranikus lands.
    auto r = Driven!self("npc_keeper_remulos", remulos, 19);
    r.raise(QuestAccepted(hero, KeeperRemulos.questNightmareManifests));
    r.walkTo(13);
    r.run(60_000);
    assert(r.host.has("summon 15491") && r.host.has("say as 15491 -1000675"));
    r.run(40_000);
    assert(r.host.has("move 15491 1") && r.host.has("move 14"), "on to the village");
    r.walkTo(17);
    r.run(11_000);
    assert(r.host.has("say -1000685") && r.host.has("faction 996"));
    r.run(6000);
    assert(r.host.has("summon 15629") && r.host.has("summon 15495"));
    r.run(400_000);
    assert(r.host.has("move 15491 2"), "the waves spent, he lands");
    r.raise(Signal(r.host.summoned[0], Nightmare.redeemed));
    r.run(7000);
    assert(r.host.has("event 8736") && r.host.has("say -1000705"));

    // Eranikus: the fight's turns as his health falls, and his redemption at a fifth.
    auto e = Driven!self("boss_eranikus", eranikusTyrant);
    e.host.owner_ = creatureRef(remulos);
    e.raise(Spawned());
    e.raise(MovementDone(Eranikus.pointLand));
    assert(e.host.has("attack 15491 11832") && e.host.has("say -1000687"));
    e.host.fighting = true;
    e.raise(EnteredCombat(hero));
    e.raise(Damaged(hero, 1000, 100, 60));
    assert(e.host.has("say -1000688") && e.host.summons == 1);
    e.raise(Damaged(hero, 1000, 60, 19));
    assert(e.host.has("say -1000696") && e.host.has("entry 15628") && e.host.summons == 9);
    e.host.fighting = false;
    e.run(21_000);
    assert(e.host.has("cast 25846") && e.host.has("move 3"));
    e.raise(MovementDone(Eranikus.pointRedeemed));
    e.run(45_000);
    assert(e.host.has("say -1000703") && e.host.has("signal 2") && e.host.has("despawn"));
}
