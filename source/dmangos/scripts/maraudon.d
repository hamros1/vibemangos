/**
 * Maraudon (map 349): the Larva Spewer near Noxxion, which spits a Spewed Larva every minute until a
 * player stops it (or Noxxion falls, which also stops the Corruption Spewer), and Noxxion himself:
 * toxic volleys, uppercuts, and his spawns.
 */
module dmangos.scripts.maraudon;

import dmangos.script;

/// Creatures and objects of Maraudon.
enum : uint
{
    noxxion = 13282,
    spewedLarva = 13533,
    larvaSpewer = 178559,
    corruptionSpewer = 178570,
}

/// What Maraudon remembers (`instance.data`).
@instance("instance_maraudon")
struct Maraudon
{
    enum Signals : uint { spewerStopped = 100 }
    enum Location larvaPlace = Location(937.213f, -377.967f, -50.346f, 2.578f);

    bool noxxionDead, spewerStopped;
    @transient EntityRef larva, corruption;

    enum Step : ubyte { spew }
    Schedule!Step steps;

    void on(ref InstanceContext mara, const ref ObjectLoaded e)
    {
        if (e.object.entry == larvaSpewer)
        {
            larva = e.object;
            if (spewerStopped || noxxionDead)
                mara.door(e.object, true);
            else if (!steps.pending(Step.spew))
                steps.every(Step.spew, 60.seconds);
        }
        else if (e.object.entry == corruptionSpewer)
        {
            corruption = e.object;
            if (noxxionDead)
                mara.door(e.object, true);
        }
    }

    void on(ref InstanceContext mara, Step step)
    {
        if (!spewerStopped && !noxxionDead)
            mara.summon(spewedLarva, larvaPlace, 10 * 60 * 1000);
    }

    void on(ref InstanceContext mara, const ref CreatureDied e)
    {
        if (e.creature.entry != noxxion)
            return;
        noxxionDead = true;
        stop(mara);
        if (corruption)
            mara.door(corruption, true);
    }

    void on(ref InstanceContext mara, const ref Signal e)
    {
        if (e.id == Signals.spewerStopped && !spewerStopped)
        {
            spewerStopped = true;
            stop(mara);
        }
    }

    private void stop(ref InstanceContext mara)
    {
        steps.clear();
        if (larva)
            mara.door(larva, true);
    }
}

/// The Larva Spewer: used, it spits no more.
@gameObject("go_larva_spewer")
struct LarvaSpewer
{
    void on(ref GameObjectContext spewer, const ref ObjectUsed e)
    {
        spewer.signalDungeon(Maraudon.Signals.spewerStopped);
    }
}

/// Noxxion: toxic volleys, uppercuts on his foe, and his spawns every forty seconds.
@creature("boss_noxxion")
struct Noxxion
{
    enum : uint { toxicVolley = 21687, uppercut = 22916, spawnsAura = 21708, spawnsSummon = 21707 }

    enum Step : ubyte { volley, uppercut, spawns }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.volley, 7.seconds);
        steps.after(Step.uppercut, 16.seconds);
        steps.after(Step.spawns, 19.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.volley:
            me.castSelf(toxicVolley);
            steps.after(Step.volley, 9.seconds);
            break;
        case Step.uppercut:
            me.castSpell(uppercut);
            steps.after(Step.uppercut, 12.seconds);
            break;
        case Step.spawns:
            if (me.castSelf(spawnsAura) == ActionResult.ok)
                me.castSelf(spawnsSummon, true);
            steps.after(Step.spawns, 40.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.maraudon;
    auto mara = runInstance!self("instance_maraudon");
    mara.raise(ObjectLoaded(objectRef(larvaSpewer)));
    mara.run(125_000);
    assert(mara.host.times("summon 13533") == 2, "a larva a minute");
    mara.raise(Signal(playerRef, Maraudon.Signals.spewerStopped));
    assert(mara.host.done("door 178559 open"));
    mara.run(125_000);
    assert(mara.host.times("summon 13533") == 2, "stopped");
}
