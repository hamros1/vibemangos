/**
 * Blackfathom Deeps (map 48): the Fires of Aku'mai (they may be lit once Twilight Lord Kelris is
 * dead; each lit fire brings a wave of Aku'mai's creatures to the shrine, and with all four waves
 * slain the Portal of Aku'mai opens), and the Fathom Stone, which calls Baron Aquanis once.
 */
module dmangos.scripts.blackfathomdeeps;

import dmangos.script;

/// Creatures and objects of the deeps.
enum : uint
{
    kelris = 4832,
    baronAquanis = 12876,
    akumaiServant = 4978,
    akumaiSnapjaw = 4825,
    barbedCrustacean = 4823,
    murkshallowSoftshell = 4977,

    portalDoor = 21117,
    shrine1 = 21118, // the four fires: 21118 to 21121
    fathomStone = 177964,
}

/// An encounter's state.
enum Fight : ubyte { notStarted, inProgress, done }

/// What the deeps remember (`instance.data`).
@instance("instance_blackfathom_deeps")
struct BlackfathomDeeps
{
    /// Signals: a fire was lit, the Fathom Stone used (from the objects' scripts); Kelris's
    /// `creature_ai_scripts` set "instance data 1" to 3 (done) as he dies.
    enum Signals : uint { kelrisData = 1, fireLit = 100, stoneUsed = 101 }

    bool kelrisDead;
    Fight shrine, aquanis;
    ubyte wavesCalled;
    /// The waves' creatures, and the baron called: not saved, as a restart takes them away (the shrine's waves are
    /// done with then; the Fathom Stone may call him again).
    @transient Pack!12[4] waves;
    @transient bool aquanisCalled;
    @transient EntityRef portal;
    @transient EntityRef[4] fires;

    /// Where the waves come from (left and right of the shrine), and Kelris's place, where they go.
    static immutable Location[6] sides = [
        Location(-768.949f, -174.413f, -25.87f, 3.09f), Location(-768.888f, -164.238f, -25.87f, 3.09f),
        Location(-768.951f, -153.911f, -25.88f, 3.09f), Location(-867.782f, -174.352f, -25.87f, 6.27f),
        Location(-867.875f, -164.089f, -25.87f, 6.27f), Location(-867.859f, -153.927f, -25.88f, 6.27f),
    ];
    enum Location shrinePlace = Location(-818.832f, -155.576f, -25.7923f);
    /// Each wave: what, and how many at each side.
    static struct Wave { uint entry; ubyte[6] count; }
    static immutable Wave[4] waveOf = [
        Wave(akumaiSnapjaw, [1, 1, 0, 0, 0, 1]),
        Wave(akumaiServant, [0, 1, 0, 0, 1, 0]),
        Wave(barbedCrustacean, [1, 0, 1, 1, 1, 0]),
        Wave(murkshallowSoftshell, [2, 1, 2, 1, 2, 2]),
    ];

    enum Step : ubyte { wave0, wave1, wave2, wave3 }
    @transient Schedule!(Step, 4) steps;

    void on(ref InstanceContext deeps, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        if (entry == portalDoor)
        {
            portal = e.object;
            if (shrine == Fight.done)
                deeps.door(e.object, true);
        }
        else if (entry >= shrine1 && entry < shrine1 + 4)
        {
            fires[entry - shrine1] = e.object;
            if (shrine == Fight.done)
                deeps.door(e.object, true);
            if (kelrisDead)
                deeps.signal(e.object, FireOfAkumai.Signals.kelrisDead);
        }
    }

    void on(ref InstanceContext deeps, const ref CreatureDied e)
    {
        if (e.creature.entry == kelris)
            kelrisFell(deeps);
        else if (e.creature.entry == baronAquanis)
            aquanis = Fight.done;
        foreach (ref wave; waves)
            wave.died(e.creature);
        if (shrine == Fight.inProgress && wavesCalled == 4 && !steps.busy)
        {
            foreach (ref wave; waves)
                if (wave.alive)
                    return;
            shrine = Fight.done;
            deeps.log("the four waves of Aku'mai are slain: the portal opens");
            if (portal)
                deeps.door(portal, true);
        }
    }

    void on(ref InstanceContext deeps, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.kelrisData:
            if (e.value == 3)
                kelrisFell(deeps);
            break;
        case Signals.fireLit:
            if (!kelrisDead || shrine == Fight.done || wavesCalled >= 4)
                break;
            shrine = Fight.inProgress;
            steps.after(cast(Step) wavesCalled++, 3.seconds);
            break;
        case Signals.stoneUsed:
            if (aquanis != Fight.done && !aquanisCalled)
            {
                aquanisCalled = true;
                aquanis = Fight.inProgress;
                deeps.summon(baronAquanis, Location(-782.21f, -63.26f, -42.43f, 2.36f));
            }
            break;
        default:
            break;
        }
    }

    /// A wave comes to the shrine.
    void on(ref InstanceContext deeps, Step step)
    {
        const index = cast(size_t) step;
        const wave = waveOf[index];
        foreach (side, count; wave.count)
            foreach (k; 0 .. count)
            {
                Location at = sides[side];
                if (count > 1)
                    at.y += -2.5f + k * 5.0f / count;
                if (const made = deeps.summon(wave.entry, at))
                {
                    waves[index].add(made);
                    deeps.moveTo(made, shrinePlace, 0, true);
                }
            }
    }

    private void kelrisFell(ref InstanceContext deeps)
    {
        if (kelrisDead)
            return;
        kelrisDead = true;
        foreach (fire; fires)
            if (fire)
                deeps.signal(fire, FireOfAkumai.Signals.kelrisDead);
    }
}

/// A Fire of Aku'mai: it cannot be lit while Kelris lives; lit (once), it calls a wave.
@gameObject("go_fire_of_akumai")
struct FireOfAkumai
{
    enum Signals : uint { kelrisDead = 1 }
    bool kelrisDead, lit;

    void on(ref GameObjectContext fire, const ref Signal e)
    {
        if (e.id == Signals.kelrisDead)
            kelrisDead = true;
    }

    void on(ref GameObjectContext fire, const ref ObjectUsed e)
    {
        if (!kelrisDead || lit)
        {
            fire.consume();
            return;
        }
        lit = true;
        fire.signalDungeon(BlackfathomDeeps.Signals.fireLit);
    }
}

/// The Fathom Stone: used, it calls Baron Aquanis (once a copy).
@gameObject("go_fathom_stone")
struct FathomStone
{
    void on(ref GameObjectContext stone, const ref ObjectUsed e)
    {
        stone.signalDungeon(BlackfathomDeeps.Signals.stoneUsed);
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackfathomdeeps;
    auto deeps = runInstance!self("instance_blackfathom_deeps");
    deeps.raise(ObjectLoaded(objectRef(portalDoor)));
    foreach (i; 0 .. 4)
        deeps.raise(ObjectLoaded(objectRef(shrine1 + i)));
    deeps.raise(Signal(objectRef(shrine1), BlackfathomDeeps.Signals.fireLit));
    deeps.run(5000);
    assert(!deeps.host.done("summon 4825"), "not while Kelris lives");
    deeps.raise(CreatureDied(creatureRef(kelris)));
    assert(deeps.host.times("signal 21118 1 0") == 1 && deeps.host.times("signal 21121 1 0") == 1);
    foreach (i; 0 .. 4)
        deeps.raise(Signal(objectRef(shrine1 + i), BlackfathomDeeps.Signals.fireLit));
    deeps.run(5000);
    assert(deeps.host.times("summon 4825") == 3 && deeps.host.times("summon 4977") == 10);
    foreach (spawn; 1 .. deeps.host.spawned + 1)
    {
        assert(!deeps.host.done("door 21117 open"));
        foreach (entry; [akumaiSnapjaw, akumaiServant, barbedCrustacean, murkshallowSoftshell])
            deeps.raise(CreatureDied(creatureRef(entry, 1000 + spawn)));
    }
    assert(deeps.host.done("door 21117 open"));
    deeps.raise(Signal(objectRef(fathomStone), BlackfathomDeeps.Signals.stoneUsed));
    deeps.raise(Signal(objectRef(fathomStone), BlackfathomDeeps.Signals.stoneUsed));
    assert(deeps.host.times("summon 12876") == 1);
}
