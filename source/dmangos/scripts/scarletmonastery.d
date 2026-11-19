/**
 * The Scarlet Monastery (map 189): the Cathedral's fight with Scarlet Commander Mograine and High
 * Inquisitor Whitemane (Mograine falls but does not die; Whitemane comes through her door, and at
 * half health puts the room to sleep and raises him; then both fight to the end), Herod in the
 * Armory, whose death calls twenty Scarlet Trainees down the hall, Arcanist Doan in the Library, and
 * Vorrel Sengutz's last word on Interrogator Vishas in the Graveyard.
 */
module dmangos.scripts.scarletmonastery;

import dmangos.script;

/// Creatures and objects of the monastery.
enum : uint
{
    mograine = 3976,
    whitemane = 3977,
    vorrel = 3981,
    vishas = 3983,
    herod = 3975,
    scarletTrainee = 6575,

    whitemaneDoor = 104600,
    chapelDoor = 104591,
}

/// The Cathedral's fight, as the monastery's script tracks it.
enum Encounter : ubyte { notStarted, inProgress, resurrected, done, failed }

/// What the monastery remembers (`instance.data`).
@instance("instance_scarlet_monastery")
struct ScarletMonastery
{
    /// Signals: Mograine fell (and is lying there), was raised, one of the two gave up (`failed`).
    enum Signals : uint { mograineFell = 100, mograineRaised = 101, failed = 102 }
    enum int sayVorrel = -1189015;

    Encounter cathedral;
    bool mograineDead, whitemaneDead;
    @transient EntityRef door, mograineRef, whitemaneRef, vorrelRef;

    void on(ref InstanceContext sm, const ref ObjectLoaded e)
    {
        if (e.object.entry == whitemaneDoor)
        {
            door = e.object;
            if (cathedral == Encounter.inProgress || cathedral == Encounter.resurrected || cathedral == Encounter.done)
                sm.door(door, true);
        }
    }

    void on(ref InstanceContext sm, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case mograine: mograineRef = e.creature; break;
        case whitemane: whitemaneRef = e.creature; break;
        case vorrel: vorrelRef = e.creature; break;
        default: break;
        }
    }

    void on(ref InstanceContext sm, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case vishas:
            if (vorrelRef)
                sm.say(vorrelRef, sayVorrel);
            break;
        case mograine:
            mograineDead = true;
            break;
        case whitemane:
            whitemaneDead = true;
            break;
        default:
            break;
        }
        if (mograineDead && whitemaneDead && cathedral != Encounter.done)
        {
            cathedral = Encounter.done;
            if (door)
                sm.door(door, true);
        }
    }

    void on(ref InstanceContext sm, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.mograineFell:
            if (cathedral != Encounter.notStarted && cathedral != Encounter.failed)
                break;
            cathedral = Encounter.inProgress;
            if (door)
                sm.door(door, true);
            if (whitemaneRef)
                sm.signal(whitemaneRef, Whitemane.Signals.mograineFell);
            break;
        case Signals.mograineRaised:
            if (cathedral == Encounter.inProgress)
                cathedral = Encounter.resurrected;
            break;
        case Signals.failed:
            if (cathedral != Encounter.inProgress && cathedral != Encounter.resurrected)
                break;
            cathedral = Encounter.failed;
            if (door)
                sm.door(door, false);
            foreach (who; [mograineRef, whitemaneRef])
                if (who && who != e.from)
                    sm.signal(who, Mograine.Signals.reset);
            break;
        default:
            break;
        }
    }
}

/**
 * Scarlet Commander Mograine: Crusader Strike, Hammer of Justice, Divine Shield at half health.
 * The first time he would die he falls instead (lying there, out of reach) and Whitemane comes;
 * raised by her, he lays hands on himself and fights on.
 */
@creature("boss_scarlet_commander_mograine")
struct Mograine
{
    enum Signals : uint { reset = 1 }
    enum : int { sayAggro = -1189005, sayKill = -1189006, sayRaised = -1189007 }
    enum : uint
    {
        crusaderStrike = 14518, hammerOfJustice = 5589, layOnHands = 9257, retributionAura = 8990,
        divineShield = 642, scarletResurrection = 9232,
    }
    enum uint emoteRoar = 15;

    enum Step : ubyte { strike, hammer, shield, layOnHands, roar, revived }
    Schedule!Step steps;
    bool fallen, raised, shielded;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (fallen)
            return;
        me.say(sayAggro);
        me.castSelf(retributionAura);
        fightSteps();
    }

    private void fightSteps()
    {
        steps.after(Step.strike, 8400.msecs);
        steps.after(Step.hammer, 9600.msecs);
        steps.every(Step.shield, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (fallen || raised || e.after > 0)
            return;
        // He falls (as if dead): out of the fight's reach until Whitemane raises him.
        fallen = true;
        steps.clear();
        me.melee(false);
        me.combatMovement(false);
        me.unitFlags(UnitFlag.immuneToNpc | UnitFlag.notSelectable);
        me.standState(StandState.dead);
        me.signalDungeon(ScarletMonastery.Signals.mograineFell);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == scarletResurrection && fallen && !raised)
        {
            me.signalDungeon(ScarletMonastery.Signals.mograineRaised);
            steps.after(Step.layOnHands, 3.seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.strike:
            me.castSpell(crusaderStrike);
            steps.after(Step.strike, (6000 + me.random(9000)).msecs);
            break;
        case Step.hammer:
            me.castSpell(hammerOfJustice);
            steps.after(Step.hammer, (7000 + me.random(11_500)).msecs);
            break;
        case Step.shield:
            if (!shielded && me.healthPercent <= 50 && me.castSelf(divineShield) == ActionResult.ok)
            {
                shielded = true;
                steps.cancel(Step.shield);
            }
            break;
        case Step.layOnHands:
            raised = true;
            me.standState(StandState.stand);
            me.say(sayRaised);
            me.deathPrevention(false);
            me.castSelf(layOnHands, true);
            steps.after(Step.roar, 500.msecs);
            steps.after(Step.revived, 2.seconds);
            break;
        case Step.roar:
            me.emote(emoteRoar);
            break;
        case Step.revived:
            me.unitFlags(0, UnitFlag.immuneToNpc | UnitFlag.notSelectable);
            me.melee(true);
            me.combatMovement(true);
            me.castSelf(retributionAura);
            shielded = false;
            fightSteps();
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.say(sayKill);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (fallen)
            me.signalDungeon(ScarletMonastery.Signals.failed);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.reset && !me.inCombat)
            standUp(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        standUp(me);
    }

    private void standUp(ref CreatureContext me)
    {
        steps.clear();
        fallen = raised = shielded = false;
        me.unitFlags(0, UnitFlag.immuneToNpc | UnitFlag.notSelectable);
        me.standState(StandState.stand);
        me.melee(true);
        me.combatMovement(true);
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/**
 * High Inquisitor Whitemane: comes when Mograine falls and joins the fight; she heals, shields
 * herself and smites. At half health she puts everyone to sleep, runs to Mograine and raises him;
 * she cannot die before that.
 */
@creature("boss_high_inquisitor_whitemane")
struct Whitemane
{
    enum Signals : uint { mograineFell = 2 }
    enum : int { sayIntro = -1189008, sayKill = -1189009, sayRaise = -1189010 }
    enum : uint
    {
        deepSleep = 9256, scarletResurrection = 9232, dominateMind = 14515, holySmite = 9481, heal = 12039,
        powerWordShield = 22187,
    }
    enum uint emoteSalute = 66;
    enum Location intoTheRoom = Location(1163.113370f, 1398.856812f, 32.527786f);
    enum : uint { pointRoom = 1, pointMograine = 2 }

    enum Step : ubyte { heal, shield, smite, dominate, sleep, raise, salute, fightAgain }
    Schedule!Step steps;
    bool came, slept, raising;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.mograineFell && !came)
        {
            came = true;
            me.say(sayIntro);
            me.moveTo(intoTheRoom, pointRoom, true);
        }
        else if (e.id == Mograine.Signals.reset && !me.inCombat)
            reset();
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == pointRoom)
        {
            if (const enemy = me.playerNearby(40))
                me.attack(enemy);
        }
        else if (e.point == pointMograine && raising)
            steps.after(Step.raise, 3.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.heal, 10.seconds);
        steps.after(Step.shield, 15.seconds);
        steps.after(Step.smite, 100.msecs);
        steps.every(Step.sleep, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.heal:
            me.castSelf(heal);
            steps.after(Step.heal, 13.seconds);
            break;
        case Step.shield:
            me.castSelf(powerWordShield);
            steps.after(Step.shield, (22_000 + me.random(23_000)).msecs);
            break;
        case Step.smite:
            if (!raising)
                me.castSpell(holySmite);
            steps.after(Step.smite, (3500 + me.random(4500)).msecs);
            break;
        case Step.dominate:
            if (me.random(50) == 0)
                if (const target = me.randomTarget())
                    me.castSpell(dominateMind, target);
            steps.after(Step.dominate, (5000 + me.random(5000)).msecs);
            break;
        case Step.sleep:
            if (slept || me.healthPercent > 50)
                break;
            slept = raising = true;
            steps.cancel(Step.sleep);
            me.castSelf(deepSleep);
            me.combatMovement(false);
            me.melee(false);
            Location at;
            const him = me.creatureNearby(mograine, 100);
            if (him && me.locate(him, at))
                me.moveTo(at, pointMograine, true);
            else
                steps.after(Step.raise, 3.seconds);
            break;
        case Step.raise:
            me.castSelf(scarletResurrection);
            me.say(sayRaise);
            steps.after(Step.salute, 3400.msecs);
            steps.after(Step.fightAgain, 5700.msecs);
            break;
        case Step.salute:
            me.emote(emoteSalute);
            break;
        case Step.fightAgain:
            raising = false;
            me.combatMovement(true);
            me.melee(true);
            me.deathPrevention(false);
            steps.after(Step.dominate, (5000 + me.random(5000)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.say(sayKill);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (came)
            me.signalDungeon(ScarletMonastery.Signals.failed);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        reset();
        me.combatMovement(true);
        me.melee(true);
        me.deathPrevention(true);
    }

    private void reset()
    {
        steps.clear();
        came = slept = raising = false;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/**
 * Herod, the Scarlet Champion: charges in, cleaves, whirls, and is frenzied near death. When he
 * dies, twenty Scarlet Trainees come down the hall to avenge him.
 */
@creature("boss_herod")
struct Herod
{
    enum : int { sayAggro = -1189000, sayWhirlwind = -1189001, sayEnrage = -1189002, sayKill = -1189003, emoteEnraged = -1000003 }
    enum : uint { rushingCharge = 8260, cleave = 15496, whirlwind = 8989, frenzy = 8269 }
    enum Location trainees = Location(1939.18f, -431.58f, 17.09f, 6.22f);

    enum Step : ubyte { cleave, whirlwind }
    Schedule!Step steps;
    bool enraged;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.castSelf(rushingCharge);
        steps.after(Step.cleave, 7500.msecs);
        steps.after(Step.whirlwind, 14_500.msecs);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after <= 30 && me.castSelf(frenzy) == ActionResult.ok)
        {
            enraged = true;
            me.say(emoteEnraged);
            me.say(sayEnrage);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.cleave:
            me.castSpell(cleave);
            steps.after(Step.cleave, (7500 + me.random(10_000)).msecs);
            break;
        case Step.whirlwind:
            if (me.castSpell(whirlwind) == ActionResult.ok)
                me.say(sayWhirlwind);
            steps.after(Step.whirlwind, (15_000 + me.random(10_000)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.say(sayKill);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        enraged = false;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        foreach (_; 0 .. 20)
            me.summon(scarletTrainee, trainees, 600_000);
    }
}

/// A Scarlet Trainee: a moment after it comes, it runs its path down the hall (its escort path).
@creature("mob_scarlet_trainee")
struct ScarletTrainee
{
    enum int sayAvenge = -1189035;
    enum Step : ubyte { start }
    Schedule!Step steps;
    uint point;
    bool walking;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.after(Step.start, (1000 + me.random(5000)).msecs);
        if (!me.creatureNearby(scarletTrainee, 3)) // the first of them calls the others
            me.say(sayAvenge);
    }

    void on(ref CreatureContext me, Step step)
    {
        walking = true;
        point = 0;
        next(me);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (walking && e.point == point)
        {
            ++point;
            next(me);
        }
    }

    private void next(ref CreatureContext me)
    {
        Waypoint w;
        if (me.waypoint(point, w))
            me.moveTo(w.at, point, true);
        else
            walking = false;
    }
}

/**
 * Arcanist Doan: arcane explosions around him, silence, and polymorph on someone he fights; at half
 * health an arcane bubble, and a detonation a moment later.
 */
@creature("boss_arcanist_doan")
struct ArcanistDoan
{
    enum : int { sayAggro = -1189019, saySpecial = -1189020 }
    enum : uint { polymorph = 13323, silence = 8988, arcaneExplosion = 9433, detonation = 9435, arcaneBubble = 9438 }

    enum Step : ubyte { polymorph, silence, explosion, detonation, bubble }
    Schedule!Step steps;
    bool shielded;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        steps.after(Step.polymorph, 15.seconds);
        steps.after(Step.silence, 7500.msecs);
        steps.after(Step.explosion, (1000 + me.random(2000)).msecs);
        steps.every(Step.bubble, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.polymorph:
            if (const target = me.randomTarget())
                if (target != me.victim)
                    me.castSpell(polymorph, target);
            steps.after(Step.polymorph, 20.seconds);
            break;
        case Step.silence:
            me.castSelf(silence);
            steps.after(Step.silence, (15_000 + me.random(7000)).msecs);
            break;
        case Step.explosion:
            me.castSelf(arcaneExplosion);
            steps.after(Step.explosion, (2500 + me.random(6000)).msecs);
            break;
        case Step.bubble:
            if (!shielded && me.healthPercent <= 50 && me.castSelf(arcaneBubble) == ActionResult.ok)
            {
                shielded = true;
                steps.cancel(Step.bubble);
                steps.after(Step.detonation, 1.seconds);
            }
            break;
        case Step.detonation:
            if (me.castSelf(detonation) == ActionResult.ok)
                me.say(saySpecial);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        shielded = false;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.scarletmonastery;
    auto sm = runInstance!self("instance_scarlet_monastery");
    sm.raise(ObjectLoaded(objectRef(whitemaneDoor)));
    sm.raise(CreatureLoaded(creatureRef(mograine)));
    sm.raise(CreatureLoaded(creatureRef(whitemane)));
    sm.raise(Signal(creatureRef(mograine), ScarletMonastery.Signals.mograineFell));
    assert(sm.host.done("door 104600 open") && sm.host.done("signal 3977 2 0"), "Whitemane comes through her door");
    sm.raise(Signal(creatureRef(whitemane), ScarletMonastery.Signals.failed));
    assert(sm.host.done("door 104600 closed") && sm.host.done("signal 3976 1 0"));
    sm.raise(Signal(creatureRef(mograine), ScarletMonastery.Signals.mograineFell));
    sm.raise(CreatureDied(creatureRef(mograine)));
    sm.raise(CreatureDied(creatureRef(whitemane)));
    assert(sm.state!ScarletMonastery.cathedral == Encounter.done);

    // Mograine falls, is raised, and fights on.
    auto mo = runCreature!self("boss_scarlet_commander_mograine", mograine);
    mo.raise(EnteredCombat(playerRef));
    mo.raise(Damaged(playerRef, 500, 5, 0));
    assert(mo.host.done("stand dead") && mo.host.done("dungeon 100 0") && mo.host.done("melee false"));
    mo.raise(SpellHit(creatureRef(whitemane), Mograine.scarletResurrection));
    mo.run(5000);
    assert(mo.host.done("say -1189007") && mo.host.done("cast 9257") && mo.host.done("death prevention false"));
    assert(mo.host.done("melee true"));

    // Whitemane: comes, and at half health puts them to sleep and raises him.
    auto wh = runCreature!self("boss_high_inquisitor_whitemane", whitemane);
    wh.host.nearby = creatureRef(mograine);
    wh.raise(Signal(EntityRef.init, Whitemane.Signals.mograineFell));
    assert(wh.host.done("say -1189008") && wh.host.done("move 1"));
    wh.raise(MovementDone(Whitemane.pointRoom));
    assert(wh.host.done("attack"));
    wh.raise(EnteredCombat(playerRef));
    wh.host.health = 45;
    wh.run(1000);
    assert(wh.host.done("cast 9256") && wh.host.done("move 2"));
    wh.raise(MovementDone(Whitemane.pointMograine));
    wh.run(9000);
    assert(wh.host.done("cast 9232") && wh.host.done("say -1189010") && wh.host.done("death prevention false"));
}
