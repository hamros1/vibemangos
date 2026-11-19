/**
 * Stratholme (map 329): the undead side's way to Baron Rivendare (each ziggurat's door opens as
 * its master falls; its acolytes slain, its crystal dies; with the three crystals dead the gates to
 * the Slaughter Square open; its abominations slain, Ramstein comes out of the slaughterhouse; after
 * him the mindless undead and the Black Guards; then the Baron's door), the Baron's run (the gauntlet
 * gate opened, Ysida Harmon has forty-five minutes; saved, she gives thanks and her quest's credit),
 * Aurius joining the fight against the Baron, the service gate and Magistrate Barthilas, the
 * postboxes and the Postmaster, Timmy the Cruel in the courtyard, and the bosses: Baroness Anastari,
 * Cannon Master Willey, Maleki the Pallid, Balnazzar.
 */
module dmangos.scripts.stratholme;

import dmangos.script;

/// Creatures of the city.
enum : uint
{
    timmy = 10808,
    barthilas = 10435,
    baroness = 10436,
    nerubenkan = 10437,
    maleki = 10438,
    ramstein = 10439,
    baron = 10440,
    balnazzar = 10813,
    dathrohan = 10812,
    crystal = 10415,
    acolyte = 10399,
    abomBile = 10416,
    abomVenom = 10417,
    mindlessUndead = 11030,
    blackGuard = 10394,
    ysida = 16031,
    aurius = 10917,
    undeadPostman = 11142,
    postmasterMalown = 11143,
    crimsonInitiate = 10420, crimsonGallant = 10424, crimsonGuardsman = 10418, crimsonConjurer = 10419,
    crimsonBattleMage = 10425,
}

/// Objects of the city.
enum : uint
{
    serviceEntrance = 175368,
    gauntletGate = 175357,
    slaughterGate = 175358,
    zigguratDoor1 = 175380, // Baroness
    zigguratDoor2 = 175379, // Nerub'enkan
    zigguratDoor3 = 175381, // Maleki
    zigguratDoor4 = 175405, // the slaughterhouse (Ramstein)
    zigguratDoor5 = 175796, // the Baron
    portGauntlet = 175374,
    portSlaughter = 175373,
    ysidaCage = 181071,
}

/// Which way an encounter has gone.
enum Fight : ubyte { notStarted, inProgress, crystalDead, done, failed }

/// What the city remembers (`instance.data`).
@instance("instance_stratholme")
struct Stratholme
{
    /// Signals from the city's objects and creatures.
    enum Signals : uint { gauntletGateUsed = 100, serviceGateUsed = 101, postboxUsed = 102, auriusRewarded = 103 }
    enum : int
    {
        sayZiggurat1 = -1329004, sayRivendare = -1329007, sayWarnBaron = -1329008, sayRunStart = -1329009,
        sayRun10 = -1329010, sayRun5 = -1329011, sayYsida5 = -1329019, sayRunFail = -1329012, sayYsidaFail = -1329020,
        sayRamstein = -1329013, sayUndeadDefeat = -1329014, sayEpilogue = -1329015, sayAuriusAggro = -1329021,
        sayAuriusDeath = -1329022,
    }
    enum uint factionVictim = 42;
    enum uint baronSoulDrain = 27640;

    static immutable Location[3] zigguratDoors = [
        Location(3853.47f, -3722.94f, 148.094f), Location(3851.7f, -3522.96f, 144.213f), Location(4038.13f, -3649.91f, 135.658f),
    ];
    static immutable Location barthilasDoor = Location(3725.577f, -3599.484f, 142.367f);
    static immutable Location ramsteinSpawn = Location(4032.643f, -3378.546f, 119.752f, 4.74f);
    static immutable Location skeletonSpawn = Location(3969.357f, -3391.871f, 119.116f, 5.91f);
    static immutable Location squareCenter = Location(4033.044f, -3431.031f, 119.055f);
    static immutable Location guardSpawn = Location(4032.602f, -3378.506f, 119.752f, 4.74f);
    static immutable Location ysidaSpawn = Location(4044.78f, -3333.68f, 115.53f, 4.15f);
    static immutable Location ysidaFree = Location(4041.9f, -3337.6f, 115.06f, 3.82f);
    static immutable Location timmySpawn = Location(3614.702f, -3187.642f, 131.406f, 4.024f);
    static immutable Location timmyCourtyard = Location(3668.60f, -3183.31f, 126.215f);

    Fight[3] ziggurats;           /// the Baroness, Nerub'enkan, Maleki
    Fight slaughter, blackGuards, baronFight, run;
    bool zigguratsSorted, squareOpen, barthilasRan, auriusDone, timmyCalled;
    int runLeftMs;                /// the Baron's run: time left
    ubyte runYells, mindlessCount, postboxesUsed;
    Pack!12[3] acolytes;
    Pack!40 mindless;
    Pack!8 guards;
    Pack!48 courtyard;            /// the Scarlet defenders around Timmy's courtyard
    EntityRef ysidaRef;

    @transient EntityRef[3] zigguratDoorRefs, crystals;
    @transient EntityRef slaughterhouse, baronDoor, gauntletPort, slaughterPort, slaughterGateRef, cage;
    @transient EntityRef baronRef, barthilasRef, auriusRef;
    @transient Pack!24 acolyteCandidates, crystalCandidates;
    @transient Pack!16 abominations;

    enum Step : ubyte { runClock, mindless, blackGuards, slaughterDoorClose, aurius }
    Schedule!(Step, 6) steps;

    void on(ref InstanceContext strat, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        foreach (i, door; [zigguratDoor1, zigguratDoor2, zigguratDoor3])
            if (entry == door)
            {
                zigguratDoorRefs[i] = e.object;
                if (ziggurats[i] == Fight.done || ziggurats[i] == Fight.crystalDead)
                    strat.door(e.object, true);
            }
        switch (entry)
        {
        case zigguratDoor4:
            slaughterhouse = e.object;
            if (slaughter == Fight.done || blackGuards == Fight.done)
                strat.door(e.object, true);
            break;
        case zigguratDoor5:
            baronDoor = e.object;
            if (blackGuards == Fight.done)
                strat.door(e.object, true);
            break;
        case portGauntlet, portSlaughter:
            (entry == portGauntlet ? gauntletPort : slaughterPort) = e.object;
            if (squareOpen)
                strat.door(e.object, true);
            break;
        case slaughterGate:
            slaughterGateRef = e.object;
            if (slaughter == Fight.done)
                strat.door(e.object, true);
            break;
        case ysidaCage: cage = e.object; break;
        default: break;
        }
    }

    void on(ref InstanceContext strat, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case baron: baronRef = e.creature; break;
        case barthilas: barthilasRef = e.creature; break;
        case aurius: auriusRef = e.creature; break;
        case acolyte: acolyteCandidates.add(e.creature); break;
        case crystal: crystalCandidates.add(e.creature); break;
        case abomBile, abomVenom: abominations.add(e.creature); break;
        case crimsonInitiate, crimsonGallant, crimsonGuardsman, crimsonConjurer, crimsonBattleMage:
            Location at;
            if (!timmyCalled && strat.locationOf(e.creature, at)
                && (at.x - timmyCourtyard.x) ^^ 2 + (at.y - timmyCourtyard.y) ^^ 2 < 40 * 40)
                courtyard.add(e.creature);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext strat, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.gauntletGateUsed:
            if (run != Fight.notStarted || !baronRef)
                break;
            run = Fight.inProgress;
            runLeftMs = 45 * 60 * 1000;
            runYells = 0;
            strat.say(baronRef, sayRunStart);
            ysidaRef = strat.summon(ysida, ysidaSpawn);
            if (ysidaRef)
                strat.unitFlags(ysidaRef, UnitFlag.notAttackable);
            steps.every(Step.runClock, 1.seconds);
            break;
        case Signals.serviceGateUsed:
            if (!barthilasRan && barthilasRef && strat.alive(barthilasRef) && !strat.victimOf(barthilasRef))
            {
                barthilasRan = true;
                strat.say(barthilasRef, sayWarnBaron);
                strat.moveTo(barthilasRef, barthilasDoor, 0, true);
                strat.despawn(barthilasRef, 8000); // gone to warn the Baron
            }
            break;
        case Signals.postboxUsed:
            Location at;
            if (!e.from || !strat.locationOf(e.from, at))
                break;
            if (++postboxesUsed == 3)
                strat.summon(postmasterMalown, at, 0, e.from);
            else if (postboxesUsed < 3)
                foreach (_; 0 .. 3)
                    strat.summon(undeadPostman, at, 0, e.from);
            break;
        case Signals.auriusRewarded:
            auriusDone = true;
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext strat, const ref CreatureEngaged e)
    {
        switch (e.creature.entry)
        {
        case abomBile, abomVenom:
            abominationsChanged(strat);
            break;
        case mindlessUndead, blackGuard:
            if (blackGuards == Fight.notStarted || blackGuards == Fight.failed)
                blackGuards = Fight.inProgress;
            break;
        case baron:
            baronFight = Fight.inProgress;
            if (baronDoor)
                strat.door(baronDoor, false);
            if (auriusDone)
                steps.after(Step.aurius, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext strat, const ref CreatureEvaded e)
    {
        switch (e.creature.entry)
        {
        case baron:
            baronFight = Fight.failed;
            if (baronDoor)
                strat.door(baronDoor, true);
            break;
        case ramstein:
            slaughter = Fight.failed;
            openSlaughterhouse(strat, true);
            break;
        case mindlessUndead, blackGuard:
            if (blackGuards == Fight.inProgress)
                blackGuards = Fight.failed;
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext strat, const ref CreatureDied e)
    {
        const entry = e.creature.entry;
        switch (entry)
        {
        case baroness, nerubenkan, maleki:
        {
            const i = entry == baroness ? 0 : entry == nerubenkan ? 1 : 2;
            if (ziggurats[i] != Fight.crystalDead)
                ziggurats[i] = Fight.done;
            sortZiggurats(strat);
            if (zigguratDoorRefs[i])
                strat.door(zigguratDoorRefs[i], true);
            break;
        }
        case acolyte:
            foreach (i, ref pack; acolytes)
                if (pack.died(e.creature) && pack.allDead && ziggurats[i] != Fight.crystalDead)
                {
                    ziggurats[i] = Fight.crystalDead;
                    strat.say(e.creature, sayZiggurat1 - cast(int) i);
                    if (crystals[i])
                        strat.castSpell(crystals[i], 7); // the crystal dies
                    if (ziggurats[0] == Fight.crystalDead && ziggurats[1] == Fight.crystalDead
                        && ziggurats[2] == Fight.crystalDead)
                        openSquare(strat);
                }
            break;
        case abomBile, abomVenom:
            abominations.died(e.creature);
            abominationsChanged(strat);
            break;
        case ramstein:
            slaughter = Fight.done;
            if (slaughterGateRef)
                strat.door(slaughterGateRef, true);
            openSlaughterhouse(strat, false);
            mindlessCount = 0;
            mindless.clear();
            guards.clear();
            foreach (_; 0 .. 5)
                if (const guard = strat.summon(blackGuard, guardSpawn))
                    guards.add(guard);
            steps.after(Step.mindless, 500.msecs);
            break;
        case mindlessUndead:
            if (mindless.died(e.creature) && mindless.allDead && mindlessCount >= 30)
                steps.after(Step.blackGuards, 60.seconds);
            break;
        case blackGuard:
            if (guards.died(e.creature) && guards.allDead && blackGuards != Fight.done)
            {
                blackGuards = Fight.done;
                if (baronRef)
                    strat.say(baronRef, sayUndeadDefeat);
                if (baronDoor)
                    strat.door(baronDoor, true);
            }
            break;
        case baron:
            baronFight = Fight.done;
            if (baronDoor)
                strat.door(baronDoor, true);
            if (run == Fight.inProgress)
                saveYsida(strat);
            if (auriusDone && auriusRef && strat.alive(auriusRef))
                strat.say(auriusRef, sayAuriusDeath);
            break;
        case aurius:
            strat.say(e.creature, sayAuriusDeath);
            break;
        case crimsonInitiate, crimsonGallant, crimsonGuardsman, crimsonConjurer, crimsonBattleMage:
            if (courtyard.died(e.creature) && courtyard.allDead && !timmyCalled)
            {
                timmyCalled = true;
                strat.summon(timmy, timmySpawn, 0, e.killer);
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext strat, Step step)
    {
        final switch (step)
        {
        case Step.runClock:
            runClock(strat, 1000);
            break;
        case Step.mindless:
            if (mindlessCount < 30)
            {
                Location to = squareCenter;
                to.x += cast(int) strat.random(41) - 20;
                to.y += cast(int) strat.random(41) - 20;
                if (const zombie = strat.summon(mindlessUndead, skeletonSpawn))
                {
                    mindless.add(zombie);
                    strat.moveTo(zombie, to, 0, true);
                }
                ++mindlessCount;
                steps.after(Step.mindless, 400.msecs);
            }
            break;
        case Step.blackGuards:
            // The Black Guards come out of the slaughterhouse.
            openSlaughterhouse(strat, true);
            foreach (guard; guards)
                if (!strat.victimOf(guard))
                    strat.moveTo(guard, squareCenter, 0, true);
            break;
        case Step.slaughterDoorClose:
            openSlaughterhouse(strat, false);
            break;
        case Step.aurius:
            if (auriusRef && strat.alive(auriusRef) && baronRef && !strat.victimOf(auriusRef))
            {
                strat.say(auriusRef, sayAuriusAggro);
                strat.setFaction(auriusRef, factionVictim);
                strat.attack(auriusRef, baronRef);
            }
            break;
        }
    }

    /// The Baron's run: warnings at ten and five minutes; at the end Ysida dies.
    private void runClock(ref InstanceContext strat, int ms)
    {
        if (run != Fight.inProgress || baronFight == Fight.inProgress)
            return;
        runLeftMs -= ms;
        if (runYells == 0 && runLeftMs <= 10 * 60 * 1000)
        {
            ++runYells;
            if (baronRef)
                strat.say(baronRef, sayRun10);
        }
        else if (runYells == 1 && runLeftMs <= 5 * 60 * 1000)
        {
            ++runYells;
            if (baronRef)
                strat.say(baronRef, sayRun5);
        }
        else if (runYells == 2 && runLeftMs <= 5 * 60 * 1000 - 10_000)
        {
            ++runYells;
            if (ysidaRef)
                strat.say(ysidaRef, sayYsida5);
        }
        if (runLeftMs <= 0)
        {
            run = Fight.failed;
            steps.cancel(Step.runClock);
            if (baronRef)
            {
                strat.say(baronRef, sayRunFail);
                if (ysidaRef)
                    strat.castSpell(baronRef, baronSoulDrain, ysidaRef);
            }
            if (ysidaRef)
            {
                strat.say(ysidaRef, sayYsidaFail);
                strat.despawn(ysidaRef, 8000);
            }
        }
    }

    private void saveYsida(ref InstanceContext strat)
    {
        run = Fight.done;
        steps.cancel(Step.runClock);
        strat.killCreditAll(ysida); // "Dead Man's Plea"
        if (cage)
            strat.door(cage, true);
        if (ysidaRef)
        {
            strat.say(ysidaRef, sayEpilogue);
            strat.moveTo(ysidaRef, ysidaFree);
            strat.unitFlags(ysidaRef, UnitFlag.notAttackable, false);
        }
    }

    /// Each master's acolytes are those around his ziggurat's door; its crystal is the one near it.
    private void sortZiggurats(ref InstanceContext strat)
    {
        if (zigguratsSorted)
            return;
        zigguratsSorted = true;
        Location at;
        foreach (who; acolyteCandidates)
            if (strat.locationOf(who, at))
                foreach (i, door; zigguratDoors)
                    if ((at.x - door.x) ^^ 2 + (at.y - door.y) ^^ 2 < 35 * 35)
                    {
                        acolytes[i].add(who);
                        break;
                    }
        foreach (who; crystalCandidates)
            if (strat.locationOf(who, at))
                foreach (i, door; zigguratDoors)
                    if ((at.x - door.x) ^^ 2 + (at.y - door.y) ^^ 2 < 50 * 50)
                    {
                        crystals[i] = who;
                        break;
                    }
    }

    private void openSquare(ref InstanceContext strat)
    {
        if (squareOpen)
            return;
        squareOpen = true;
        if (baronRef)
            strat.say(baronRef, sayRivendare);
        foreach (port; [gauntletPort, slaughterPort])
            if (port)
                strat.door(port, true);
    }

    /// With the square's abominations slain, Ramstein comes out of the slaughterhouse.
    private void abominationsChanged(ref InstanceContext strat)
    {
        if (slaughter == Fight.done || slaughter == Fight.inProgress)
            return;
        if (abominations.alive > 0)
            return;
        slaughter = Fight.inProgress;
        openSlaughterhouse(strat, true);
        steps.after(Step.slaughterDoorClose, 10.seconds);
        if (baronRef)
            strat.say(baronRef, sayRamstein);
        if (const him = strat.summon(ramstein, ramsteinSpawn))
            strat.moveTo(him, squareCenter, 0, false);
    }

    private void openSlaughterhouse(ref InstanceContext strat, bool open)
    {
        if (slaughterhouse)
            strat.door(slaughterhouse, open);
    }
}

/// The gauntlet's first gate: opened, the Baron's run begins.
@gameObject("go_gauntlet_gate")
struct GauntletGate
{
    void on(ref GameObjectContext gate, const ref ObjectUsed e)
    {
        gate.signalDungeon(Stratholme.Signals.gauntletGateUsed);
    }
}

/// The service entrance: opened, Magistrate Barthilas runs to warn the Baron.
@gameObject("go_service_gate")
struct ServiceGate
{
    void on(ref GameObjectContext gate, const ref ObjectUsed e)
    {
        gate.signalDungeon(Stratholme.Signals.serviceGateUsed);
    }
}

/// A postbox of Stratholme: opened (with the key), its postmen come; the third brings the Postmaster.
@gameObject("go_stratholme_postbox")
struct Postbox
{
    bool opened;

    void on(ref GameObjectContext box, const ref ObjectUsed e)
    {
        if (opened)
            return;
        opened = true;
        box.signalDungeon(Stratholme.Signals.postboxUsed);
    }
}

/// Aurius: given the Medallion of Faith, he will fight the Baron at the players' side; he kneels.
@creature("npc_aurius")
struct Aurius
{
    enum uint questMedallion = 5122;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.kneel);
    }

    void on(ref CreatureContext me, const ref QuestRewarded e)
    {
        if (e.quest == questMedallion)
        {
            me.signalDungeon(Stratholme.Signals.auriusRewarded);
            me.npcFlags(0);
            me.standState(StandState.stand);
        }
    }
}

/// Baroness Anastari: banshee wail and curse, silence, and her possession of a player.
@creature("boss_baroness_anastari")
struct BaronessAnastari
{
    enum : uint { bansheeWail = 16565, bansheeCurse = 16867, silence = 18327, possess = 17244 }

    enum Step : ubyte { wail, curse, silence, possess }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.wail, 1.msecs);
        steps.after(Step.curse, 10.seconds);
        steps.after(Step.silence, 25.seconds);
        steps.after(Step.possess, 15.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.wail:
            if (const target = me.randomTarget())
                me.castSpell(bansheeWail, target);
            steps.after(Step.wail, (2000 + me.random(1000)).msecs);
            break;
        case Step.curse:
            me.castSelf(bansheeCurse);
            steps.after(Step.curse, 20.seconds);
            break;
        case Step.silence:
            if (const target = me.randomTarget())
                me.castSpell(silence, target);
            steps.after(Step.silence, 25.seconds);
            break;
        case Step.possess:
            if (const target = me.randomTarget())
                if (target != me.victim && target.isPlayer)
                    me.castSpell(possess, target);
            steps.after(Step.possess, 30.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// Cannon Master Willey: pummel, knock away, shots at those out of reach, and riflemen.
@creature("boss_cannon_master_willey")
struct CannonMasterWilley
{
    enum : uint { knockAway = 10101, pummel = 15615, shoot = 16496, summonRifleman = 17279 }

    enum Step : ubyte { shoot, pummel, knock, riflemen }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.shoot, 1.seconds);
        steps.after(Step.pummel, 7.seconds);
        steps.after(Step.knock, 11.seconds);
        steps.after(Step.riflemen, 15.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shoot:
            if (const target = me.randomTarget())
                if (me.distanceTo(target) > 5)
                    me.castSpell(shoot, target);
            steps.after(Step.shoot, (3000 + me.random(1000)).msecs);
            break;
        case Step.pummel:
            me.castSpell(pummel);
            steps.after(Step.pummel, 12.seconds);
            break;
        case Step.knock:
            me.castSpell(knockAway);
            steps.after(Step.knock, 14.seconds);
            break;
        case Step.riflemen:
            me.castSelf(summonRifleman);
            steps.after(Step.riflemen, 30.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// Maleki the Pallid: frost armor, frostbolts, ice tomb, life and mana drains.
@creature("boss_maleki_the_pallid")
struct Maleki
{
    enum : uint { frostArmor = 12556, frostbolt = 17503, drainLife = 17238, drainMana = 17243, iceTomb = 16869 }

    enum Step : ubyte { bolt, tomb, drainLife, drainMana }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(frostArmor, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.bolt, 1.msecs);
        steps.after(Step.tomb, 15.seconds);
        steps.after(Step.drainLife, 20.seconds);
        steps.after(Step.drainMana, 30.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        const target = me.randomTarget();
        final switch (step)
        {
        case Step.bolt:
            if (target)
                me.castSpell(frostbolt, target);
            steps.after(Step.bolt, (3000 + me.random(1000)).msecs);
            break;
        case Step.tomb:
            if (target && target != me.victim)
                me.castSpell(iceTomb, target);
            steps.after(Step.tomb, (15_000 + me.random(5000)).msecs);
            break;
        case Step.drainLife:
            if (target)
                me.castSpell(drainLife, target);
            steps.after(Step.drainLife, (15_000 + me.random(5000)).msecs);
            break;
        case Step.drainMana:
            if (target)
                me.castSpell(drainMana, target);
            steps.after(Step.drainMana, (20_000 + me.random(10_000)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.castSelf(frostArmor, true);
    }
}

/**
 * Grand Crusader Dathrohan: crusader's hammer and strike, holy strike, mind blast; below two fifths
 * of his health he shows himself as Balnazzar: shadow shock, psychic scream, sleep, mind control.
 */
@creature("boss_dathrohan_balnazzar")
struct Balnazzar
{
    enum : int { sayAggro = -1329016, sayTransform = -1329017, sayDeath = -1329018 }
    enum : uint
    {
        crusadersHammer = 17286, crusaderStrike = 17281, holyStrike = 17284, transform = 17288, shadowShock = 17399,
        mindBlast = 17287, psychicScream = 13704, sleep = 12098, mindControl = 15690,
    }

    enum Step : ubyte { hammer, strike, mindBlast, holyStrike, shock, scream, sleep, control }
    Schedule!Step steps;
    bool transformed;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        steps.after(Step.hammer, 8.seconds);
        steps.after(Step.strike, 12.seconds);
        steps.after(Step.mindBlast, 6.seconds);
        steps.after(Step.holyStrike, 18.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!transformed && e.after < 40 && me.castSelf(transform) == ActionResult.ok)
        {
            transformed = true;
            me.changeEntry(balnazzar);
            me.say(sayTransform);
            me.restoreEquipment();
            steps.clear();
            steps.after(Step.mindBlast, 6.seconds);
            steps.after(Step.shock, 4.seconds);
            steps.after(Step.scream, 16.seconds);
            steps.after(Step.sleep, 20.seconds);
            steps.after(Step.control, 10.seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.hammer:
            me.castSpell(crusadersHammer);
            steps.after(Step.hammer, 12.seconds);
            break;
        case Step.strike:
            me.castSpell(crusaderStrike);
            steps.after(Step.strike, 15.seconds);
            break;
        case Step.mindBlast:
            me.castSpell(mindBlast);
            steps.after(Step.mindBlast, (15_000 + me.random(5000)).msecs);
            break;
        case Step.holyStrike:
            me.castSpell(holyStrike);
            steps.after(Step.holyStrike, 15.seconds);
            break;
        case Step.shock:
            me.castSpell(shadowShock);
            steps.after(Step.shock, 11.seconds);
            break;
        case Step.scream:
            if (const target = me.randomTarget())
                me.castSpell(psychicScream, target);
            steps.after(Step.scream, 20.seconds);
            break;
        case Step.sleep:
            if (const target = me.randomTarget())
                me.castSpell(sleep, target);
            steps.after(Step.sleep, 15.seconds);
            break;
        case Step.control:
            me.castSpell(mindControl);
            steps.after(Step.control, 15.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (transformed)
            me.changeEntry(dathrohan);
        transformed = false;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
    }
}

/// The blaster of Egan's quest ("The Restless Souls") and what it does to Stratholme's spirits.
enum : uint { eganBlaster = 17368, soulFreed = 17370, summonFreedSoul = 17408, restlessSoul = 11122, freedSoul = 11136 }

/**
 * A Restless Soul: struck by Egan's Blaster from one on "The Restless Souls" (quest 5282), it is
 * freed a moment later (a Freed Soul for a minute), and the one who freed it is credited.
 */
@creature("mob_restless_soul")
struct RestlessSoul
{
    enum uint quest = 5282;
    enum int sayZapped1 = -1329000;
    enum Step : ubyte { free }
    Schedule!Step steps;
    EntityRef tagger;

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (tagger || e.spell != eganBlaster || !e.caster.isPlayer
            || me.questStatus(e.caster, quest) != QuestProgress.incomplete)
            return;
        tagger = e.caster;
        steps.after(Step.free, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.changeEntry(freedSoul);
        me.despawn(60_000);
        const pick = me.random(7);
        if (pick < 4)
            me.say(sayZapped1 - cast(int) pick);
        me.killCredit(tagger, restlessSoul);
    }
}

/// A Spectral or Ghostly Citizen: struck by Egan's Blaster, its soul is freed and it is gone.
@creature("mobs_spectral_ghostly_citizen")
struct SpectralCitizen
{
    enum uint incorporealDefense = 16331;
    enum Step : ubyte { gone }
    Schedule!Step steps;
    bool tagged;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(incorporealDefense, true);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (tagged || e.spell != eganBlaster)
            return;
        tagged = true;
        me.castSelf(soulFreed);
        me.combatMovement(false);
        me.melee(false);
        steps.after(Step.gone, 2.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.castSelf(summonFreedSoul, true);
        me.despawn();
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.stratholme;
    auto strat = runInstance!self("instance_stratholme");
    foreach (door; [zigguratDoor1, zigguratDoor2, zigguratDoor3, zigguratDoor4, zigguratDoor5, portGauntlet, portSlaughter, ysidaCage])
        strat.raise(ObjectLoaded(objectRef(door)));
    strat.raise(CreatureLoaded(creatureRef(baron)));
    // The fake places everything at one spot: make it the first ziggurat's door, its acolytes there.
    foreach (spawn; 1 .. 4)
        strat.raise(CreatureLoaded(creatureRef(acolyte, spawn)));
    strat.raise(CreatureLoaded(creatureRef(abomBile, 1)));

    // The run.
    strat.raise(Signal(objectRef(gauntletGate), Stratholme.Signals.gauntletGateUsed));
    assert(strat.host.done("say 10440 -1329009") && strat.host.done("summon 16031"));
    strat.run(35 * 60 * 1000 + 1000);
    assert(strat.host.done("say 10440 -1329010"));

    // The Baroness falls: her door opens.
    strat.raise(CreatureDied(creatureRef(baroness)));
    assert(strat.host.done("door 175380 open"));

    // The abominations slain: Ramstein; his death: the undead, then the guards; then the Baron's door.
    strat.raise(CreatureEngaged(creatureRef(abomBile, 1), playerRef));
    strat.raise(CreatureDied(creatureRef(abomBile, 1)));
    assert(strat.host.done("summon 10439") && strat.host.done("door 175405 open"));
    strat.raise(CreatureDied(creatureRef(ramstein, 1002)));
    strat.run(15_000);
    assert(strat.host.times("summon 11030") == 30 && strat.host.times("summon 10394") == 5);
    foreach (spawn; 1003 .. 1003 + 35)
    {
        strat.raise(CreatureDied(creatureRef(mindlessUndead, spawn)));
        strat.raise(CreatureDied(creatureRef(blackGuard, spawn)));
    }
    assert(strat.host.done("door 175796 open") && strat.host.done("say 10440 -1329014"));

    // The Baron dies in time: Ysida is saved.
    strat.raise(CreatureDied(creatureRef(baron)));
    assert(strat.host.done("credit 16031") && strat.host.done("door 181071 open") && strat.host.done("say 16031 -1329015"));
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.stratholme;
    auto soul = runCreature!self("mob_restless_soul", restlessSoul);
    soul.raise(SpellHit(playerRef, eganBlaster));
    soul.run(2000);
    assert(!soul.host.done("credit 11122"), "not on the quest: nothing");
    soul.host.progress = QuestProgress.incomplete;
    soul.raise(SpellHit(playerRef, eganBlaster));
    soul.run(2000);
    assert(soul.host.done("become 11136") && soul.host.done("credit 11122"));
}
