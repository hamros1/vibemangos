/**
 * Zul'Farrak (map 209): the pyramid (the prisoners' cage unlocked, the Sandfury come out of the
 * temple and climb the steps by twos and threes until Nekrum and Sezz'ziz are slain, which opens
 * the way on), the gong that calls Gahz'rilla (once), Antu'sul, who comes for whoever walks into his
 * basin, and Witch Doctor Zum'rah, who turns on those who come near and raises the dead of the
 * graveyard against them.
 */
module dmangos.scripts.zulfarrak;

import dmangos.script;

/// Creatures and objects of Zul'Farrak.
enum : uint
{
    velratha = 7795,
    gahzrilla = 7273,
    antusul = 8127,
    theka = 7272,
    zumrah = 7271,
    nekrum = 7796,
    sezzziz = 7275,
    sandscalp = 7267,
    sergeantBly = 7604,
    sandfurySlave = 7787,
    sandfuryDrudge = 7788,
    sandfuryCretin = 7789,
    sandfuryAcolyte = 8876,
    sandfuryZealot = 8877,
    zombie = 7286,
    deadHero = 7276,

    shallowGrave = 128403,
    endDoor = 146084,
}

/// The gong's event (event_go_zulfarrak_gong) and the cage's (event_spell_unlocking).
enum : uint { gongEvent = 2488, unlockingEvent = 2609 }

/// An encounter's state.
enum Fight : ubyte { notStarted, inProgress, done, failed }

/// What Zul'Farrak remembers (`instance.data`).
@instance("instance_zulfarrak")
struct ZulFarrak
{
    /// Signals: someone walked into Antu'sul's basin (`from`: the player); Zum'rah raises the dead.
    enum Signals : uint { antusulTrigger = 100, raiseDead = 101 }

    Fight gahzrillaFight, antusulFight, pyramid;
    bool nekrumDead, sezzzizDead;
    Pack!96 trolls;                  /// the Sandfury of the pyramid
    Pack!16 graves;                  /// "dead" once Zum'rah has raised theirs
    @transient EntityRef antusulRef, blyRef, zumrahRef, door;

    enum Step : ubyte { sendTroll }
    Schedule!Step steps;

    void on(ref InstanceContext zf, const ref ObjectLoaded e)
    {
        if (e.object.entry == shallowGrave)
            graves.add(e.object);
        else if (e.object.entry == endDoor)
        {
            door = e.object;
            if (pyramid == Fight.done)
                zf.door(e.object, true);
        }
    }

    void on(ref InstanceContext zf, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case antusul: antusulRef = e.creature; break;
        case sergeantBly: blyRef = e.creature; break;
        case zumrah: zumrahRef = e.creature; break;
        case sandfurySlave, sandfuryDrudge, sandfuryCretin, sandfuryAcolyte, sandfuryZealot:
            trolls.add(e.creature);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext zf, const ref EventHappened e)
    {
        if (e.event == gongEvent)
        {
            if (gahzrillaFight == Fight.notStarted || gahzrillaFight == Fight.failed)
                gahzrillaFight = Fight.inProgress; // the event's database script brings her
            else
                zf.consume(); // she came already
        }
        else if (e.event == unlockingEvent)
        {
            if (pyramid == Fight.notStarted)
            {
                pyramid = Fight.inProgress; // the database script brings the Sandfury
                steps.after(Step.sendTroll, 20.seconds);
            }
            else
                zf.consume();
        }
    }

    /// One more troll runs up the steps to Sergeant Bly.
    void on(ref InstanceContext zf, Step step)
    {
        if (pyramid != Fight.inProgress)
            return;
        if (blyRef && !zf.alive(blyRef))
            return; // the prisoners are lost: the trolls stay where they are
        const n = trolls.alive;
        if (n > 0)
        {
            uint pick = zf.random(n);
            foreach (troll; trolls)
                if (pick-- == 0)
                {
                    if (!zf.victimOf(troll))
                    {
                        Location at;
                        if (!blyRef || !zf.locationOf(blyRef, at))
                            at = Location(1882.89f, 1299.27f, 48.38f);
                        at.x += (cast(int) zf.random(9) - 4) * 0.5f;
                        at.y += (cast(int) zf.random(9) - 4) * 0.5f;
                        zf.moveTo(troll, at, 0, true);
                    }
                    break;
                }
        }
        steps.after(Step.sendTroll, (zf.random(3) ? 3000 + zf.random(7000) : 1000).msecs);
    }

    void on(ref InstanceContext zf, const ref CreatureDied e)
    {
        trolls.died(e.creature);
        switch (e.creature.entry)
        {
        case gahzrilla: gahzrillaFight = Fight.done; break;
        case antusul: antusulFight = Fight.done; break;
        case nekrum: nekrumDead = true; break;
        case sezzziz: sezzzizDead = true; break;
        default: break;
        }
        if (nekrumDead && sezzzizDead && pyramid != Fight.done)
        {
            pyramid = Fight.done;
            steps.clear();
            zf.log("Nekrum and Sezz'ziz are slain: the way on opens");
            if (door)
                zf.door(door, true);
        }
    }

    void on(ref InstanceContext zf, const ref CreatureEngaged e)
    {
        if (e.creature.entry == antusul)
            antusulFight = Fight.inProgress;
    }

    void on(ref InstanceContext zf, const ref CreatureEvaded e)
    {
        if (e.creature.entry == gahzrilla && gahzrillaFight == Fight.inProgress)
            gahzrillaFight = Fight.failed;
        else if (e.creature.entry == antusul && antusulFight == Fight.inProgress)
            antusulFight = Fight.failed;
    }

    void on(ref InstanceContext zf, const ref Signal e)
    {
        if (e.id == Signals.antusulTrigger)
        {
            if ((antusulFight == Fight.notStarted || antusulFight == Fight.failed) && antusulRef && zf.alive(antusulRef))
                zf.attack(antusulRef, e.from);
        }
        else if (e.id == Signals.raiseDead && zumrahRef)
        {
            // The grave nearest Zum'rah gives up its dead.
            Location boss, at, nearest;
            EntityRef best;
            float bestDistance = float.infinity;
            if (!zf.locationOf(zumrahRef, boss))
                return;
            foreach (grave; graves)
                if (zf.locationOf(grave, at))
                {
                    const d = (at.x - boss.x) ^^ 2 + (at.y - boss.y) ^^ 2;
                    if (d < bestDistance)
                    {
                        bestDistance = d;
                        best = grave;
                        nearest = at;
                    }
                }
            if (!best)
                return;
            graves.died(best);
            const target = zf.victimOf(zumrahRef);
            zf.summon(zombie, nearest, 0, target);
            zf.summon(zf.random(2) ? zombie : deadHero, nearest, 0, target);
        }
    }
}

/// Antu'sul's basin: whoever walks in, he comes for.
@areaTrigger("at_zulfarrak")
struct AntusulBasin
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (e.trigger == 1447)
            at.signalDungeon(ZulFarrak.Signals.antusulTrigger);
    }
}

/**
 * Witch Doctor Zum'rah: keeps to himself until a player comes within nine yards; then turns
 * hostile. Shadow bolts at those he fights, a volley at all, his ward, healing waves, and every
 * twenty seconds the dead of a grave raised against them.
 */
@creature("boss_zumrah")
struct Zumrah
{
    enum : int { sayIntro = -1209000, sayAggro = -1209001, sayKill = -1209002, saySummon = -1209003 }
    enum : uint { shadowBolt = 12739, shadowBoltVolley = 15245, wardOfZumrah = 11086, healingWave = 12491 }
    enum uint factionHostile = 14;

    enum Step : ubyte { watch, bolt, volley, ward, heal, graves }
    Schedule!Step steps;
    bool hostile;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.every(Step.watch, 1.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        steps.after(Step.bolt, 1.seconds);
        steps.after(Step.volley, (6000 + me.random(24_000)).msecs);
        steps.after(Step.ward, (7000 + me.random(13_000)).msecs);
        steps.after(Step.heal, (10_000 + me.random(5000)).msecs);
        steps.after(Step.graves, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.watch:
            if (hostile || me.inCombat)
                return;
            if (const player = me.playerNearby(9))
            {
                hostile = true;
                steps.cancel(Step.watch);
                me.setFaction(factionHostile);
                me.say(sayIntro);
                me.attack(player);
            }
            break;
        case Step.bolt:
            if (const target = me.randomTarget())
                me.castSpell(shadowBolt, target);
            steps.after(Step.bolt, (3500 + me.random(1500)).msecs);
            break;
        case Step.volley:
            me.castSelf(shadowBoltVolley);
            steps.after(Step.volley, (10_000 + me.random(8000)).msecs);
            break;
        case Step.ward:
            me.castSelf(wardOfZumrah);
            steps.after(Step.ward, (15_000 + me.random(17_000)).msecs);
            break;
        case Step.heal:
            me.castSelf(healingWave);
            steps.after(Step.heal, (15_000 + me.random(8000)).msecs);
            break;
        case Step.graves:
            me.signalDungeon(ZulFarrak.Signals.raiseDead);
            if (me.random(10) < 3)
                me.say(saySummon);
            steps.after(Step.graves, 20.seconds);
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
        if (!hostile)
            steps.every(Step.watch, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// The Gong of Zul'Farrak (`event_go_zulfarrak_gong`): the dungeon's script lets Gahz'rilla come once
/// (`EventHappened`; the event's database script brings her); the event's own script lets it through to it.
@scriptedEvent("event_go_zulfarrak_gong")
struct ZulFarrakGongEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

/// The troll cage unlocked (`event_spell_unlocking`): the dungeon's script starts the pyramid's siege once
/// (`EventHappened`; the event's database script frees the prisoners and brings the Sandfury); the event's own
/// script lets it through to it.
@scriptedEvent("event_spell_unlocking")
struct PyramidUnlockingEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.zulfarrak;
    auto zf = runInstance!self("instance_zulfarrak");
    zf.raise(ObjectLoaded(objectRef(endDoor)));
    zf.raise(CreatureLoaded(creatureRef(sergeantBly)));
    foreach (spawn; 1 .. 6)
        zf.raise(CreatureLoaded(creatureRef(sandfuryDrudge, spawn)));
    zf.host.fought = EntityRef.init;
    zf.raise(EventHappened(unlockingEvent, playerRef, EntityRef.init));
    zf.run(20_000);
    assert(zf.host.times("move 7788 0") == 1, "the first troll runs up");
    zf.run(30_000);
    assert(zf.host.times("move 7788 0") > 2);
    zf.raise(CreatureDied(creatureRef(nekrum)));
    zf.raise(CreatureDied(creatureRef(sezzziz)));
    assert(zf.host.done("door 146084 open"));

    // Antu'sul's trigger, and the graves raised for Zum'rah.
    zf.raise(CreatureLoaded(creatureRef(antusul)));
    zf.raise(Signal(playerRef, ZulFarrak.Signals.antusulTrigger));
    assert(zf.host.done("attack 8127"));
    zf.raise(CreatureLoaded(creatureRef(zumrah)));
    zf.raise(ObjectLoaded(objectRef(shallowGrave, 1)));
    zf.raise(Signal(creatureRef(zumrah), ZulFarrak.Signals.raiseDead));
    assert(zf.host.done("summon 7286"));
    zf.host.forget();
    zf.raise(Signal(creatureRef(zumrah), ZulFarrak.Signals.raiseDead));
    assert(!zf.host.done("summon 7286"), "each grave once");

    auto boss = runCreature!self("boss_zumrah", zumrah);
    boss.raise(Spawned());
    boss.run(1000);
    assert(boss.host.done("faction 14") && boss.host.done("attack"));
}
