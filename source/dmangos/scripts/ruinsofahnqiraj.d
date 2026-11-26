/**
 * The Ruins of Ahn'Qiraj (map 509): the copy's script (its six encounters, General Andorov and his
 * Kaldorei arriving once Kurinnaxx falls, the Qiraji army's waves against Rajaxx's challengers, the
 * crystals that weaken Ossirian), the bosses Kurinnaxx, Andorov and the Kaldorei Elites, Moam, Buru the
 * Gorger and his eggs, Ayamiss the Hunter and her larvae, Ossirian the Unscarred and his crystals, and the
 * Anubisath Guardians.
 */
module dmangos.scripts.ruinsofahnqiraj;

import core.time : Duration;

import dmangos.script;

/// Where `who` is, as `ctx` sees it (`Location.init` if it is not here).
private Location where(C)(ref C ctx, EntityRef who)
{
    Location at;
    ctx.locationOf(who, at);
    return at;
}

/// The copy's encounters (CMaNGOS's `TYPE_*`).
enum Aq20Encounter : ubyte
{
    kurinnaxx,
    rajaxx,
    moam,
    buru,
    ayamiss,
    ossirian,
}

/// Creatures and objects of the copy.
enum : uint
{
    npcKurinnaxx = 15348,
    npcMoam = 15340,
    npcBuru = 15370,
    npcAyamiss = 15369,
    npcOssirian = 15339,
    npcAndorov = 15471,
    npcKaldoreiElite = 15473,
    npcRajaxx = 15341,
    npcColonelZerran = 15385,
    npcMajorPakkon = 15388,
    npcMajorYeggeth = 15386,
    npcCaptainXurrem = 15390,
    npcCaptainDrenn = 15389,
    npcCaptainTuubid = 15392,
    npcCaptainQeez = 15391,
    npcQirajiWarrior = 15387,
    npcSwarmguardNeedler = 15344,
    npcOssirianTrigger = 15590,
    npcBuruEgg = 15514,
    npcHatchling = 15521,
    npcManaFiend = 15527,
    npcLarva = 15555,
    npcSwarmer = 15546,
    npcSandVortex = 15428,

    goOssirianCrystal = 180619,
}

/// What scripts of the copy say to each other, beyond the encounters' states (ids 0 .. 5).
enum Aq20Signal : uint
{
    rajaxxDone = 100,  /// the copy to Andorov: the army is beaten
    weakened = 101,    /// the copy to Ossirian: a crystal weakened him (`value`: the weakness)
    crystalUsed = 102, /// a crystal to the copy
    eggBurst = 103,    /// an egg to Buru: it burst near him
    startEvent = 104,  /// Andorov to the copy: the army comes (after his words)
}

/// The waves of the army, in order: their captain and Rajaxx's yell as they come.
private static immutable uint[7] waveCaptains = [npcCaptainQeez, npcCaptainTuubid, npcCaptainDrenn,
    npcCaptainXurrem, npcMajorYeggeth, npcMajorPakkon, npcColonelZerran];
private static immutable int[7] waveYells = [0, 0, -1_509_005, -1_509_006, -1_509_007, -1_509_008, -1_509_009];

/// Andorov and his four Kaldorei, where they come.
private static immutable Location[5] andorovSpawns = [
    Location(-8660.4f, 1510.29f, 32.449f, 2.2184f),
    Location(-8655.84f, 1509.78f, 32.462f, 2.33341f),
    Location(-8657.39f, 1506.28f, 32.418f, 2.33346f),
    Location(-8660.96f, 1504.9f, 32.1567f, 2.33306f),
    Location(-8664.45f, 1506.44f, 32.0944f, 2.33302f),
];
/// Andorov's way: to the gates, the place he waits, and where he fights.
private static immutable Location[5] andorovMoves = [
    Location(-8701.51f, 1561.80f, 32.092f),
    Location(-8718.66f, 1577.69f, 21.612f),
    Location(-8876.97f, 1651.96f, 21.57f, 5.52f),
    Location(-8882.15f, 1602.77f, 21.386f),
    Location(-8940.45f, 1550.69f, 21.616f),
];

/// Ossirian's weaknesses: fire, frost, nature, arcane, shadow.
private static immutable uint[5] weaknesses = [25177, 25178, 25180, 25181, 25183];

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/// What the copy remembers: its encounters (saved in `instance.data`).
@instance("instance_ruins_of_ahnqiraj")
struct RuinsOfAhnQiraj
{
    enum int sayOssirianIntro = -1_509_022, sayRajaxxIntro = -1_509_010;

    EncounterState[Aq20Encounter.max + 1] encounters;

    @transient EntityRef ossirian, rajaxx, andorov;
    @transient EntityRef[4] kaldorei; /// Andorov's Kaldorei Elites
    @transient EntityRef[7] captains;
    @transient EntityRef[12] triggers;
    @transient ubyte triggerCount;
    @transient EntityRef[6] crystals;
    @transient ubyte wave;
    @transient EntityRef[24] waveMembers;
    /// Restored with the army under way: the wave fighting is found again at the next look (`findWave`); Rajaxx's
    /// death landed and the save after it did not (`rajaxxDoneDue`).
    @transient bool findWave, rajaxxDoneDue;

    enum Step : ubyte { nextWave, waveCheck }
    Schedule!Step steps;

    private bool armyActive() const
    {
        return encounters[Aq20Encounter.rajaxx] == EncounterState.inProgress;
    }

    private bool ossirianActive() const
    {
        return encounters[Aq20Encounter.ossirian] == EncounterState.inProgress;
    }

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case npcOssirian:
            ossirian = e.creature;
            break;
        case npcRajaxx:
            rajaxx = e.creature;
            break;
        case npcAndorov:
            if (!e.summoned)
                break;
            andorov = e.creature;
            if (armyActive && copy.alive(andorov)) // a clean handoff: he stays in the checkpoint
                copy.checkpointCreature(andorov);
            break;
        case npcKaldoreiElite:
            import std.algorithm.searching : canFind;

            if (!e.summoned || kaldorei[].canFind(e.creature))
                break;
            foreach (ref elite; kaldorei)
                if (!elite)
                {
                    elite = e.creature;
                    if (armyActive && copy.alive(elite))
                        copy.checkpointCreature(elite);
                    break;
                }
            break;
        case npcOssirianTrigger:
            if (triggerCount < triggers.length)
            {
                // In the order of their spawns: the first is the one by the entrance.
                size_t i = triggerCount++;
                triggers[i] = e.creature;
                while (i > 0 && (triggers[i - 1].guid & 0xFF_FFFF) > (triggers[i].guid & 0xFF_FFFF))
                {
                    const t = triggers[i - 1];
                    triggers[i - 1] = triggers[i];
                    triggers[i] = t;
                    --i;
                }
            }
            break;
        default:
            foreach (i, entry; waveCaptains)
                if (e.creature.entry == entry)
                    captains[i] = e.creature;
            break;
        }
    }

    void on(ref InstanceContext copy, const ref PlayerEntered e)
    {
        if (rajaxxDoneDue)
        {
            rajaxxDoneDue = false;
            set(copy, Aq20Encounter.rajaxx, EncounterState.done); // Andorov, back from the checkpoint, trades
        }
        if (encounters[Aq20Encounter.kurinnaxx] == EncounterState.done)
            summonAndorov(copy);
        if (!crystals[0] && encounters[Aq20Encounter.ossirian] != EncounterState.done && triggerCount)
            crystals[0] = copy.summonObject(goOssirianCrystal, where(copy, triggers[0]));
    }

    /**
     * The copy came back from its save. With the army under way, Andorov and his Kaldorei come back from the
     * checkpoint when a player does, and the wave fighting then is found again (`findWave`): the army's timers wait
     * for the raid. Ossirian's fight under way brings back the crystals placed in it.
     */
    void on(ref InstanceContext copy, const ref Restored e)
    {
        if (armyActive)
        {
            if (copy.entryKilled(npcRajaxx)) // his death landed, the save after it did not
            {
                encounters[Aq20Encounter.rajaxx] = EncounterState.done;
                steps.clear();
                rajaxxDoneDue = true;
                copy.checkpoint();
            }
            else
            {
                findWave = true;
                if (!steps.pending(Step.waveCheck))
                    steps.every(Step.waveCheck, 5.seconds);
            }
            copy.waitForPlayer();
        }
        if (ossirianActive)
        {
            if (copy.entryKilled(npcOssirian))
            {
                encounters[Aq20Encounter.ossirian] = EncounterState.done;
                copy.checkpoint();
            }
            copy.waitForPlayer();
        }
    }

    /// A crystal of Ossirian's fight back from the checkpoint (or with a clean handoff): one of his again.
    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        import std.algorithm.searching : canFind;

        if (e.object.entry != goOssirianCrystal || crystals[].canFind(e.object))
            return;
        size_t slot = 1;
        while (slot < crystals.length && crystals[slot])
            ++slot;
        if (!crystals[0] && triggerCount)
        {
            const at = where(copy, e.object), entrance = where(copy, triggers[0]);
            if ((at.x - entrance.x) ^^ 2 + (at.y - entrance.y) ^^ 2 < 25)
                slot = 0; // the one by the entrance
        }
        if (slot < crystals.length)
            crystals[slot] = e.object;
        if (slot > 0 && ossirianActive)
            copy.checkpointObject(e.object);
    }

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id <= Aq20Encounter.max)
            copy.answer(encounters[e.id]);
    }

    void on(ref InstanceContext copy, const ref CreatureEngaged e)
    {
        switch (e.creature.entry)
        {
        case npcKurinnaxx:
            set(copy, Aq20Encounter.kurinnaxx, EncounterState.inProgress);
            break;
        case npcMoam:
            set(copy, Aq20Encounter.moam, EncounterState.inProgress);
            break;
        case npcBuru:
            set(copy, Aq20Encounter.buru, EncounterState.inProgress);
            break;
        case npcAyamiss:
            set(copy, Aq20Encounter.ayamiss, EncounterState.inProgress);
            break;
        case npcOssirian:
            set(copy, Aq20Encounter.ossirian, EncounterState.inProgress);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case npcKurinnaxx:
            set(copy, Aq20Encounter.kurinnaxx, EncounterState.done);
            break;
        case npcRajaxx:
            set(copy, Aq20Encounter.rajaxx, EncounterState.done);
            break;
        case npcMoam:
            set(copy, Aq20Encounter.moam, EncounterState.done);
            break;
        case npcBuru:
            set(copy, Aq20Encounter.buru, EncounterState.done);
            break;
        case npcAyamiss:
            set(copy, Aq20Encounter.ayamiss, EncounterState.done);
            break;
        case npcOssirian:
            set(copy, Aq20Encounter.ossirian, EncounterState.done);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, const ref ObjectUsedHere e)
    {
        if (e.object.entry != goOssirianCrystal)
            return;
        // The nearest trigger weakens Ossirian; the crystal is spent; the next appears elsewhere.
        const at = where(copy, e.object);
        EntityRef nearest;
        float best = 15;
        foreach (t; triggers[0 .. triggerCount])
        {
            const l = where(copy, t);
            const d = ((l.x - at.x) ^^ 2 + (l.y - at.y) ^^ 2) ^^ 0.5f;
            if (d < best)
            {
                best = d;
                nearest = t;
            }
        }
        const weakness = weaknesses[copy.random(weaknesses.length)];
        if (nearest && ossirian)
            copy.castSpell(nearest, weakness, ossirian);
        if (ossirian)
            copy.signal(ossirian, Aq20Signal.weakened, weakness);
        foreach (i, ref c; crystals)
            if (c == e.object)
            {
                if (i > 0)
                    copy.releaseCheckpointActor(c);
                c = EntityRef.init;
            }
        copy.despawnObject(e.object);
        spawnCrystals(copy, 1);
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        switch (e.id)
        {
        case Aq20Signal.startEvent:
            set(copy, Aq20Encounter.rajaxx, EncounterState.inProgress);
            return;
        case Aq20Signal.crystalUsed: // the crystal's script: its use is handled with `ObjectUsedHere`
            return;
        case 0: .. case Aq20Encounter.max:
            set(copy, cast(Aq20Encounter) e.id, cast(EncounterState) e.value);
            return;
        default:
            if (e.id == ossirianSpawnCrystals)
                spawnCrystals(copy, cast(uint) e.value);
            return;
        }
    }

    /// Ossirian asks for crystals (`value` of them).
    enum uint ossirianSpawnCrystals = 105;

    /// `count` crystals at triggers chosen at random (the first, by the entrance, left out).
    private void spawnCrystals(ref InstanceContext copy, uint count)
    {
        if (triggerCount < 2)
            return;
        foreach (_; 0 .. count)
        {
            size_t slot = size_t.max;
            foreach (i, c; crystals[1 .. $])
                if (!c)
                {
                    slot = i + 1;
                    break;
                }
            if (slot == size_t.max)
                return;
            const trigger = triggers[1 + copy.random(triggerCount - 1)];
            crystals[slot] = copy.summonObject(goOssirianCrystal, where(copy, trigger));
            // Placed in his fight: saved with it, so that a worker's crash does not leave him supreme for good.
            if (crystals[slot] && ossirianActive)
                copy.checkpointObject(crystals[slot]);
        }
    }

    /// The crystals placed in Ossirian's fight are no longer saved with it (it ended); a wipe takes them away.
    private void releaseCrystals(ref InstanceContext copy, bool despawn)
    {
        foreach (ref c; crystals[1 .. $])
            if (c)
            {
                copy.releaseCheckpointActor(c);
                if (despawn)
                {
                    copy.despawnObject(c);
                    c = EntityRef.init;
                }
            }
    }

    /// An encounter's new state, and what follows.
    private void set(ref InstanceContext copy, Aq20Encounter which, EncounterState state)
    {
        const was = encounters[which];
        encounters[which] = state;
        final switch (which)
        {
        case Aq20Encounter.kurinnaxx:
            if (state == EncounterState.done && was != EncounterState.done)
            {
                summonAndorov(copy);
                if (ossirian)
                    copy.say(ossirian, sayOssirianIntro);
            }
            break;
        case Aq20Encounter.rajaxx:
            if (state == EncounterState.inProgress && was != EncounterState.inProgress)
            {
                // Andorov and his Kaldorei fight the army: saved with it, so that a worker's crash brings them back.
                foreach (ally; andorov ~ kaldorei[])
                    if (ally && copy.alive(ally))
                        copy.checkpointCreature(ally);
                wave = 0;
                findWave = false;
                sendWave(copy);
                steps.every(Step.waveCheck, 5.seconds);
                copy.checkpoint();
            }
            else if (state != EncounterState.inProgress)
            {
                foreach (ally; andorov ~ kaldorei[])
                    if (ally)
                        copy.releaseCheckpointActor(ally);
                findWave = false;
                steps.clear();
                if (state == EncounterState.done && andorov && copy.alive(andorov))
                    copy.signal(andorov, Aq20Signal.rajaxxDone);
            }
            break;
        case Aq20Encounter.ossirian:
            if (state != EncounterState.inProgress)
                releaseCrystals(copy, state == EncounterState.failed);
            break;
        case Aq20Encounter.moam, Aq20Encounter.buru, Aq20Encounter.ayamiss:
            break;
        }
    }

    /// Andorov and his Kaldorei come, once (in this run of the server).
    private void summonAndorov(ref InstanceContext copy)
    {
        if (andorov || copy.playerCount == 0 || encounters[Aq20Encounter.rajaxx] == EncounterState.done)
            return;
        foreach (i, at; andorovSpawns)
        {
            const made = copy.summon(i == 0 ? npcAndorov : npcKaldoreiElite, at);
            if (i == 0)
                andorov = made;
        }
    }

    /// The next wave of the army charges; the last is Rajaxx himself.
    private void sendWave(ref InstanceContext copy)
    {
        if (encounters[Aq20Encounter.rajaxx] != EncounterState.inProgress)
            return;
        waveMembers[] = EntityRef.init;
        if (wave >= waveCaptains.length)
        {
            if (rajaxx)
            {
                copy.say(rajaxx, sayRajaxxIntro);
                copy.zoneCombat(rajaxx);
            }
            steps.cancel(Step.nextWave);
            steps.cancel(Step.waveCheck);
            return;
        }
        if (const captain = captains[wave])
        {
            // The captain and his company: the warriors and needlers around him.
            size_t n;
            if (copy.alive(captain))
                waveMembers[n++] = captain;
            const at = where(copy, captain);
            n += copy.creaturesNear(at, npcQirajiWarrior, 25, waveMembers[n .. $]);
            n += copy.creaturesNear(at, npcSwarmguardNeedler, 25, waveMembers[n .. $]);
            foreach (m; waveMembers[0 .. n])
                copy.zoneCombat(m);
        }
        if (waveYells[wave] && rajaxx)
            copy.say(rajaxx, waveYells[wave]);
        ++wave;
        steps.after(Step.nextWave, 3 * 60.seconds);
    }

    /**
     * After a worker's crash, which wave is under way: the first whose captain lives is next, or fights already (the
     * army fighting the raid is that wave); waves beaten stay beaten. False while no player alive is back to tell.
     */
    private bool foundWave(ref InstanceContext copy)
    {
        const raider = copy.anyPlayer();
        if (!raider)
            return false;
        findWave = false;
        ubyte first;
        while (first < waveCaptains.length && copy.entryKilled(waveCaptains[first]))
            ++first;
        bool fighting(EntityRef c) { return c && copy.alive(c) && copy.alive(copy.victimOf(c)); }
        if (first == waveCaptains.length && fighting(rajaxx))
        {
            // Rajaxx himself fights: the waves are over.
            wave = cast(ubyte)(waveCaptains.length + 1);
            steps.cancel(Step.nextWave);
            steps.cancel(Step.waveCheck);
            return false;
        }
        wave = cast(ubyte)(first < waveCaptains.length && fighting(captains[first]) ? first + 1 : first);
        // The army fighting the raid now is the wave under way.
        waveMembers[] = EntityRef.init;
        size_t n;
        const at = where(copy, raider);
        foreach (entry; waveCaptains[] ~ [npcQirajiWarrior, npcSwarmguardNeedler])
        {
            EntityRef[24] near;
            foreach (c; near[0 .. copy.creaturesNear(at, entry, 150, near[])])
                if (n < waveMembers.length && fighting(c))
                    waveMembers[n++] = c;
        }
        return true;
    }

    void on(ref InstanceContext copy, Step step)
    {
        final switch (step)
        {
        case Step.nextWave:
            if (findWave && !foundWave(copy))
            {
                if (findWave) // nobody alive back yet: the wave comes once someone is
                    steps.after(step, 5.seconds);
                break;
            }
            sendWave(copy);
            break;
        case Step.waveCheck:
            if (findWave && !foundWave(copy))
                break;
            // The wave beaten before its three minutes: the next comes at once.
            foreach (m; waveMembers)
                if (m && copy.alive(m))
                    return;
            if (wave <= waveCaptains.length)
                sendWave(copy);
            break;
        }
    }
}

/// Kurinnaxx: Mortal Wound, Sand Trap, Thrash, Wide Slash, and enraged below 30%.
@creature("boss_kurinnaxx")
struct Kurinnaxx
{
    enum int sayEnrage = -1_000_002;
    enum : uint { thrash = 3391, wideSlash = 25814, mortalWound = 25646, sandtrap = 26524, enrage = 26527 }
    enum Step : ubyte { mortalWound, sandTrap, thrash, wideSlash }
    Schedule!Step steps;
    bool enraged;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.mortalWound, between(me, 8000, 10_000));
        steps.after(Step.sandTrap, between(me, 5000, 10_000));
        steps.after(Step.thrash, between(me, 1000, 5000));
        steps.after(Step.wideSlash, between(me, 10_000, 15_000));
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after <= 30 && me.castSelf(enrage) == ActionResult.ok)
        {
            enraged = true;
            me.say(sayEnrage);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.mortalWound:
            steps.after(step, me.castSpell(mortalWound) == ActionResult.ok ? between(me, 8000, 10_000) : retry);
            break;
        case Step.sandTrap:
            steps.after(step, me.castSpell(sandtrap) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.thrash:
            steps.after(step, me.castSelf(thrash) == ActionResult.ok ? between(me, 12_000, 17_000) : retry);
            break;
        case Step.wideSlash:
            steps.after(step, me.castSpell(wideSlash) == ActionResult.ok ? between(me, 12_000, 15_000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        enraged = false;
        me.signalDungeon(Aq20Encounter.kurinnaxx, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/**
 * Lieutenant General Andorov: comes with four Kaldorei Elites once Kurinnaxx falls, walks to the ruins'
 * gates and waits; asked, he leads the attack that brings the Qiraji army out (and Rajaxx at its end).
 * The army beaten, he trades his wares for a while, and goes.
 */
@creature("npc_general_andorov")
struct GeneralAndorov
{
    enum : int
    {
        sayIntro1 = -1_509_004,
        sayIntro2 = -1_509_031,
        sayIntro3 = -1_509_003,
        sayIntro4 = -1_509_029,
        sayAttackStart = -1_509_030,
        sayDespawn = -1_509_032,
    }
    enum : uint { auraOfCommand = 25516, bash = 25515, strike = 22591 }
    enum : uint { textIntro = 7883 }
    enum : uint { npcFlagGossip = 1, npcFlagVendor = 0x80 }

    enum Step : ubyte { move, dialogue, despawn, command, bash, strike }
    Schedule!Step steps;
    ubyte point, dialogueStep;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.after(Step.move, 5.seconds);
        me.npcFlags(0);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (e.point)
        {
        case 0, 1, 3:
            ++point;
            me.moveTo(andorovMoves[point], point, true);
            follow(me);
            break;
        case 2:
            ++point;
            if (me.askDungeon(Aq20Encounter.rajaxx) == EncounterState.inProgress)
            {
                // Come again while the army fights (a worker's crash lost the one who led it): on to the fight.
                me.unitFlags(UnitFlag.immuneToNpc, false);
                me.moveTo(andorovMoves[point], point, true);
                follow(me);
            }
            else
                me.npcFlags(npcFlagGossip);
            break;
        case 4:
            if (point == 4)
            {
                ++point;
                if (me.askDungeon(Aq20Encounter.rajaxx) != EncounterState.inProgress)
                {
                    dialogueStep = 2;
                    steps.after(Step.dialogue, 0.msecs);
                }
            }
            break;
        default:
            break;
        }
    }

    /// His Kaldorei go where he goes.
    private void follow(ref CreatureContext me)
    {
        EntityRef[4] elites;
        foreach (elite; elites[0 .. me.creaturesNearby(npcKaldoreiElite, 40, elites[])])
            me.signal(elite, Aq20Signal.startEvent, cast(int) point);
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        const state = me.askDungeon(Aq20Encounter.rajaxx);
        if (state == EncounterState.inProgress)
            return;
        GossipMenu menu;
        if (state == EncounterState.notStarted || state == EncounterState.failed)
            menu.add(GossipIcon.chat, "Let's find out.", 1);
        if (state == EncounterState.done)
            menu.add(GossipIcon.vendor, "Let's see what you have.", 2);
        me.sendGossip(e.player, textIntro, menu, false);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action == 2)
            return; // the trade: the usual vendor window
        me.consume();
        me.closeGossip(e.player);
        if (e.action != 1 || point < 3)
            return;
        me.moveTo(andorovMoves[point], point, true);
        me.npcFlags(0);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        follow(me);
        dialogueStep = 0;
        steps.after(Step.dialogue, 0.msecs);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Aq20Signal.rajaxxDone)
        {
            me.npcFlags(npcFlagGossip | npcFlagVendor);
            steps.after(Step.despawn, 135.seconds);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.command, between(me, 1000, 3000));
        steps.after(Step.bash, between(me, 8000, 11_000));
        steps.after(Step.strike, between(me, 2000, 5000));
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.move:
            me.moveTo(andorovMoves[point], point, true);
            follow(me);
            break;
        case Step.dialogue:
            switch (dialogueStep++)
            {
            case 0:
                me.say(sayIntro1);
                steps.after(step, 7.seconds);
                break;
            case 1:
                me.say(sayIntro2); // and on, at the place he fights
                break;
            case 2:
                me.say(sayIntro3);
                steps.after(step, 4.seconds);
                break;
            case 3:
                me.say(sayIntro4);
                steps.after(step, 6.seconds);
                break;
            case 4:
                me.say(sayAttackStart);
                me.signalDungeon(Aq20Signal.startEvent);
                break;
            default:
                break;
            }
            break;
        case Step.despawn:
            me.say(sayDespawn);
            me.despawn(2500);
            break;
        case Step.command:
            steps.after(step, me.castSelf(auraOfCommand) == ActionResult.ok ? between(me, 30_000, 45_000) : retry);
            break;
        case Step.bash:
            steps.after(step, me.castSpell(bash) == ActionResult.ok ? between(me, 12_000, 15_000) : retry);
            break;
        case Step.strike:
            steps.after(step, me.castSpell(strike) == ActionResult.ok ? between(me, 4000, 6000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        foreach (s; [Step.command, Step.bash, Step.strike])
            steps.cancel(s);
        // Back to where he stands in the event.
        me.moveTo(andorovMoves[point >= 4 ? 4 : 2], point >= 4 ? 4 : 2, true);
    }
}

/// A Kaldorei Elite of Andorov's: goes with him, and fights with Cleave and Mortal Strike.
@creature("npc_kaldorei_elite")
struct KaldoreiElite
{
    enum : uint { cleave = 26350, mortalStrike = 16856 }
    enum Step : ubyte { cleave, strike }
    Schedule!Step steps;
    ubyte point;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Aq20Signal.startEvent || e.value >= andorovMoves.length)
            return;
        point = cast(ubyte) e.value;
        const l = andorovMoves[point];
        // Beside him, by where it stands now.
        me.moveTo(Location(l.x + me.random(5) - 2.0f, l.y + me.random(5) - 2.0f, l.z, l.orientation), 100 + point, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.cleave, between(me, 2000, 4000));
        steps.after(Step.strike, between(me, 8000, 11_000));
    }

    void on(ref CreatureContext me, Step step)
    {
        if (step == Step.cleave)
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? between(me, 5000, 7000) : retry);
        else
            steps.after(step, me.castSpell(mortalStrike) == ActionResult.ok ? between(me, 9000, 13_000) : retry);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/**
 * Moam: Trample, Double Attack and Drain Mana; Arcane Eruption when his mana is full; every ninety
 * seconds three mana fiends, and after three minutes he turns to stone to drink the mana around him
 * (for ninety seconds, or until the fiends are slain).
 */
@creature("boss_moam")
struct Moam
{
    enum : int { emoteAggro = -1_509_000, emoteManaFull = -1_509_001, emoteEnergizing = -1_509_028 }
    enum : uint { trample = 15550, doubleAttack = 18941, drainMana = 25676, arcaneEruption = 25672, energize = 25685 }
    enum Step : ubyte { eruption, trample, doubleAttack, drain, fiends, energize, cancelEnergize, fiendCheck }
    Schedule!Step steps;
    EntityRef[3] fiends;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(emoteAggro);
        steps.after(Step.eruption, 0.msecs);
        steps.after(Step.trample, 9.seconds);
        steps.after(Step.doubleAttack, between(me, 8000, 12_000));
        steps.after(Step.drain, 6.seconds);
        steps.after(Step.fiends, 90.seconds);
        steps.after(Step.energize, 90.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.eruption:
            // It only goes off with his mana full.
            if (me.castSelf(arcaneEruption) == ActionResult.ok)
            {
                me.say(emoteManaFull);
                steps.after(step, 5.seconds);
            }
            else
                steps.after(step, 1.seconds);
            break;
        case Step.trample:
            steps.after(step, me.castSpell(trample) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.doubleAttack:
            steps.after(step, me.castSelf(doubleAttack) == ActionResult.ok ? between(me, 8000, 12_000) : retry);
            break;
        case Step.drain:
            steps.after(step, me.castSelf(drainMana) == ActionResult.ok ? 6.seconds : retry);
            break;
        case Step.fiends:
            foreach (ref f; fiends)
            {
                const target = me.selectTarget(Pick.random, PickFilter.player);
                f = me.summon(npcManaFiend, Location.init, 0, target);
            }
            steps.after(Step.fiendCheck, 1.seconds);
            steps.after(step, 90.seconds);
            break;
        case Step.energize:
            if (me.castSelf(energize) == ActionResult.ok)
            {
                me.say(emoteEnergizing);
                steps.after(Step.cancelEnergize, 90.seconds);
                steps.after(step, 180.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.cancelEnergize:
            me.removeAura(me.self, energize);
            break;
        case Step.fiendCheck:
            // The fiends slain: he wakes from the stone.
            foreach (f; fiends)
                if (f && me.alive(f))
                {
                    steps.after(step, 1.seconds);
                    return;
                }
            me.removeAura(me.self, energize);
            break;
        }
    }

    /// A fiend slain (or gone) is no longer waited for. (Summoned to go when dead, a slain fiend leaves the map at
    /// once, and `alive` of a creature not here says yes: without this he stayed stone.)
    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        foreach (ref f; fiends)
            if (f == e.summoned)
                f = EntityRef.init;
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.signalDungeon(Aq20Encounter.moam, EncounterState.failed);
        foreach (ref f; fiends)
            if (f)
            {
                me.despawn(f);
                f = EntityRef.init;
            }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/**
 * Buru the Gorger: pursues one player at a time, gathering speed; every egg that bursts near him hurts him
 * and turns him to someone else. Below a fifth of his health he transforms and fights all, spreading
 * Creeping Plague.
 */
@creature("boss_buru")
struct Buru
{
    enum int emoteTarget = -1_509_002;
    enum : uint
    {
        creepingPlague = 20512,
        dismember = 96,
        gatheringSpeed = 1834,
        fullSpeed = 1557,
        thorns = 25640,
        buruTransform = 24721,
    }
    enum Step : ubyte { dismember, plague, gathering, full, transform, newTarget }
    Schedule!Step steps;
    bool transformed;
    ubyte transformStep;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(emoteTarget, e.enemy);
        me.castSelf(thorns);
        steps.after(Step.dismember, 5.seconds);
        newTarget(me);
    }

    /// Someone else to pursue.
    private void newTarget(ref CreatureContext me)
    {
        if (transformed)
            return;
        me.removeAura(me.self, fullSpeed);
        me.removeAura(me.self, gatheringSpeed);
        me.resetThreat();
        if (const target = me.selectTarget(Pick.random, PickFilter.player))
        {
            me.addThreat(target, 1_000_000);
            me.attack(target);
            me.say(emoteTarget, target);
        }
        steps.after(Step.full, 60.seconds);
        steps.after(Step.gathering, 9.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim == me.victim)
            steps.after(Step.newTarget, 0.msecs);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Aq20Signal.eggBurst || transformed)
            return;
        // An egg burst beside him: it hurts, and he turns.
        const hp = me.healthPercent;
        me.setHealthPercent(hp > 16 ? hp - 15 : 1);
        steps.after(Step.newTarget, 0.msecs);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!transformed && e.after < 20)
        {
            transformed = true;
            steps.clear();
            me.resetThreat();
            me.melee(false);
            me.combatMovement(false);
            transformStep = 0;
            steps.after(Step.transform, 2.seconds);
            steps.after(Step.plague, 0.msecs);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.dismember:
            steps.after(step, me.castSpell(dismember) == ActionResult.ok ? 5.seconds : retry);
            break;
        case Step.plague:
            steps.after(step, me.castSelf(creepingPlague) == ActionResult.ok ? 6.seconds : retry);
            break;
        case Step.gathering:
            steps.after(step, me.castSelf(gatheringSpeed) == ActionResult.ok ? 9.seconds : retry);
            break;
        case Step.full:
            if (me.castSelf(fullSpeed) == ActionResult.ok)
            {
                me.removeAura(me.self, gatheringSpeed);
                steps.cancel(Step.gathering);
            }
            else
                steps.after(step, retry);
            break;
        case Step.newTarget:
            newTarget(me);
            break;
        case Step.transform:
            if (transformStep++ == 0)
            {
                me.castSelf(buruTransform);
                me.removeAura(me.self, thorns);
                // His eggs hatch.
                EntityRef[16] eggs;
                foreach (egg; eggs[0 .. me.creaturesNearby(npcBuruEgg, 200, eggs[])])
                {
                    me.summon(npcHatchling, where(me, egg), 0, me.selectTarget(Pick.random));
                    me.despawn(egg);
                }
                steps.after(step, 5.seconds);
            }
            else
            {
                me.castSelf(fullSpeed, true);
                me.melee(true);
                me.combatMovement(true);
            }
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        transformed = false;
        me.melee(true);
        me.combatMovement(true);
        me.signalDungeon(Aq20Encounter.buru, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// A Buru Egg: never moves or fights; slain, it bursts (hurting Buru if he is near, and calling him to
/// someone else) and a hatchling comes out.
@creature("npc_buru_egg")
struct BuruEgg
{
    enum uint explode = 19593;
    bool burst;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        me.reactState(Reaction.passive);
        me.melee(false);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (burst || e.after > 0)
            return;
        burst = true;
        me.castSelf(explode, true);
        EntityRef[1] buru;
        if (me.creaturesNearby(npcBuru, 25, buru[]))
            me.signal(buru[0], Aq20Signal.eggBurst);
        EntityRef[1] near;
        me.summon(npcHatchling, me.location, 0, me.playersNear(30, near[]) ? near[0] : EntityRef.init);
    }
}

/**
 * Ayamiss the Hunter: in the air above her altar (rooted, stinging, her swarmers gathering and diving),
 * paralyzing a player at the altar for her larvae to feed on; at 70% she lands and fights with Lash and
 * Thrash; frenzied below a fifth.
 */
@creature("boss_ayamiss")
struct Ayamiss
{
    enum int emoteFrenzy = -1_000_002;
    enum : uint
    {
        stingerSpray = 25749,
        poisonStinger = 25748,
        paralyze = 25725,
        lash = 25852,
        frenzy = 8269,
        thrash = 3391,
    }
    static immutable swarmerAnchor = Location(-9647.352f, 1578.062f, 55.32f);
    static immutable altar = Location(-9717.18f, 1517.72f, 27.4677f);
    static immutable airAt = Location(-9689.292f, 1547.912f, 48.02729f);
    static immutable Location[3] landing = [Location(-9689.98f, 1548.3f, 33.2773f),
        Location(-9682.72f, 1554.25f, 31.4162f), Location(-9677.92f, 1558.84f, 27.2495f)];
    enum : uint { pointAir = 2, pointLand = 10 }

    enum Step : ubyte { paralyze, spray, stinger, summonSwarmer, swarmerAttack, lash, thrash }
    Schedule!Step steps;
    bool grounded, frenzied;
    EntityRef paralyzed;
    EntityRef[16] swarmers;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.combatMovement(false);
        me.melee(false);
        me.flying(true);
        me.moveNow(airAt, pointAir);
        steps.after(Step.paralyze, 15.seconds);
        steps.after(Step.spray, between(me, 20_000, 30_000));
        steps.after(Step.stinger, 5.seconds);
        steps.after(Step.summonSwarmer, 5.seconds);
        steps.after(Step.swarmerAttack, 60.seconds);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (!me.inCombat)
            return;
        if (e.point == pointAir)
            me.rooted(true);
        else if (e.point >= pointLand && e.point < pointLand + landing.length - 1)
            me.moveNow(landing[e.point - pointLand + 1], e.point + 1);
        else if (e.point == pointLand + landing.length - 1)
        {
            me.combatMovement(true);
            if (const victim = me.selectTarget(Pick.topThreat))
                me.attack(victim);
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!grounded && e.after <= 70)
        {
            grounded = true;
            me.rooted(false);
            me.melee(true);
            me.flying(false);
            me.resetThreat();
            me.moveNow(landing[0], pointLand);
            steps.cancel(Step.stinger);
            steps.after(Step.lash, between(me, 5000, 8000));
            steps.after(Step.thrash, between(me, 3000, 6000));
        }
        if (!frenzied && e.after < 20 && me.castSelf(frenzy) == ActionResult.ok)
        {
            frenzied = true;
            me.say(emoteFrenzy);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.paralyze:
            auto target = me.selectTarget(Pick.random, PickFilter.player, 1);
            if (!target)
                target = me.selectTarget(Pick.random, PickFilter.player);
            if (target && me.castSpell(paralyze, target) == ActionResult.ok)
            {
                // At the altar, for a larva to feed on.
                paralyzed = target;
                me.summon(npcLarva, altar, 0, target);
                steps.after(step, 15.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.spray:
            steps.after(step, me.castSelf(stingerSpray) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.stinger:
            const target = me.selectTarget(Pick.topThreat, PickFilter.player);
            const ok = target && me.castSpell(poisonStinger, target) == ActionResult.ok;
            steps.after(step, !ok ? retry : grounded ? between(me, 6000, 12_000) : between(me, 2000, 3000));
            break;
        case Step.summonSwarmer:
            foreach (ref s; swarmers)
                if (!s || !me.alive(s))
                {
                    s = me.summon(npcSwarmer, Location(swarmerAnchor.x + me.random(10) - 5.0f,
                        swarmerAnchor.y + me.random(10) - 5.0f, swarmerAnchor.z));
                    break;
                }
            steps.after(step, 5.seconds);
            break;
        case Step.swarmerAttack:
            foreach (ref s; swarmers)
                if (s && me.alive(s))
                {
                    if (const target = me.selectTarget(Pick.random, PickFilter.player))
                        me.attack(s, target);
                    s = EntityRef.init;
                }
            steps.after(step, 60.seconds);
            break;
        case Step.lash:
            steps.after(step, me.castSpell(lash) == ActionResult.ok ? between(me, 8000, 15_000) : retry);
            break;
        case Step.thrash:
            steps.after(step, me.castSelf(thrash) == ActionResult.ok ? between(me, 5000, 7000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        me.rooted(false);
        me.flying(false);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        grounded = frenzied = false;
        me.combatMovement(false);
        me.melee(false);
        foreach (ref s; swarmers)
            if (s)
            {
                me.despawn(s);
                s = EntityRef.init;
            }
        me.signalDungeon(Aq20Encounter.ayamiss, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// A Hive'Zara Larva: while Ayamiss fights it goes for the paralyzed player at the altar and feeds on it.
@creature("npc_hive_zara_larva")
struct HiveZaraLarva
{
    enum uint feed = 25721;
    enum Step : ubyte { feed }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (me.askDungeon(Aq20Encounter.ayamiss) == EncounterState.inProgress)
            steps.every(Step.feed, 500.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        const prey = me.victim;
        if (prey && me.distanceTo(prey) < 5)
        {
            me.castSpell(feed, prey, true);
            steps.cancel(Step.feed);
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/**
 * Ossirian the Unscarred: Supreme (all but unkillable) until a crystal weakens him to one school, for
 * 45 seconds; Cyclone, Stomp, Curse of Tongues; sand vortices roam his arena. The copy places the
 * crystals; the first by the entrance waits there before the fight.
 */
@creature("boss_ossirian")
struct Ossirian
{
    enum : int
    {
        saySupreme1 = -1_509_018,
        sayRandIntro1 = -1_509_021,
        sayRandIntro2 = -1_509_023,
        sayRandIntro3 = -1_509_024,
        sayAggro = -1_509_025,
        sayDeath = -1_509_027,
    }
    enum uint slayText = 11450;
    enum : uint { curseOfTongues = 25195, cyclone = 25189, stomp = 25188, supreme = 25176, sandStorm = 25160,
        doubleAttack = 19818 }
    static immutable Location[2] vortices = [Location(-9523.482f, 1880.435f, 85.645f, 5.08f),
        Location(-9321.39f, 1822.968f, 84.266f, 3.16f)];

    enum Step : ubyte { initialSpawn, supreme, cyclone, stomp, curse }
    Schedule!Step steps;
    bool introSaid;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        auras(me);
    }

    private void auras(ref CreatureContext me)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
        if (!me.hasAura(me.self, supreme))
            me.castSelf(supreme, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        foreach (at; vortices)
            if (const vortex = me.summon(npcSandVortex, at))
                me.castAs(vortex, sandStorm, vortex, true);
        steps.after(Step.initialSpawn, 10.seconds);
        steps.after(Step.supreme, 45.seconds);
        steps.after(Step.cyclone, 20.seconds);
        steps.after(Step.stomp, 30.seconds);
        steps.after(Step.curse, 30.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Aq20Signal.weakened)
            return;
        me.removeAura(me.self, supreme);
        steps.after(Step.supreme, 45.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.sayText(slayText);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.initialSpawn:
            me.signalDungeon(RuinsOfAhnQiraj.ossirianSpawnCrystals, 5);
            break;
        case Step.supreme:
            if (me.hasAura(me.self, supreme) || me.castSelf(supreme) == ActionResult.ok)
            {
                me.say(saySupreme1 - cast(int) me.random(3));
                steps.after(step, 45.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.cyclone:
            steps.after(step, me.castSpell(cyclone) == ActionResult.ok ? 20.seconds : retry);
            break;
        case Step.stomp:
            steps.after(step, me.castSelf(stomp) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.curse:
            steps.after(step, me.castSelf(curseOfTongues) == ActionResult.ok ? between(me, 20_000, 30_000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        auras(me);
        EntityRef[4] v;
        foreach (vortex; v[0 .. me.creaturesNearby(npcSandVortex, 300, v[])])
            me.despawn(vortex);
        me.signalDungeon(Aq20Encounter.ossirian, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
    }
}

/// An Ossirian Crystal: used, it weakens Ossirian (the copy does it, as it hears of the use).
@gameObject("go_ossirian_crystal")
struct OssirianCrystal
{
    void on(ref GameObjectContext crystal, const ref ObjectUsed e)
    {
        crystal.consume();
    }
}

/**
 * An Anubisath Guardian: two of meteor or plague, shadow storm or thunderclap, a reflection, enrage or
 * explosion when nearly dead, and swarmguards or warriors summoned (four at most), each drawn as it spawns.
 */
@creature("mob_anubisath_guardian")
struct AnubisathGuardian
{
    enum int emoteFrenzy = -1_000_002;
    enum : uint
    {
        meteor = 24340,
        plague = 22997,
        shadowStorm = 26546,
        thunderClap = 26554,
        reflectArcaneFire = 13022,
        reflectFrostShadow = 19595,
        enrage = 8599,
        explode = 25698,
        npcAnubWarrior = 15537,
        npcAnubSwarm = 15538,
    }
    enum Step : ubyte { spell1, spell2, summon }
    Schedule!Step steps;
    uint spell1, spell2, spell3, spell4, summonEntry;
    bool enraged;
    EntityRef[4] summoned;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        draw(me);
    }

    private void draw(ref CreatureContext me)
    {
        spell1 = me.random(2) ? meteor : plague;
        spell2 = me.random(2) ? shadowStorm : thunderClap;
        spell3 = me.random(2) ? reflectArcaneFire : reflectFrostShadow;
        spell4 = me.random(2) ? enrage : explode;
        summonEntry = me.random(2) ? npcAnubSwarm : npcAnubWarrior;
        enraged = false;
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(spell3);
        steps.after(Step.spell1, 10.seconds);
        steps.after(Step.spell2, 20.seconds);
        steps.after(Step.summon, 10.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (enraged || e.after >= 10)
            return;
        if (spell4 == enrage)
        {
            me.say(emoteFrenzy);
            me.castSelf(enrage);
            enraged = true;
        }
        else
            me.castSpell(explode);
    }

    /// One it called, slain, frees its place (as the swarmers'): it calls again.
    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        foreach (ref s; summoned)
            if (s == e.summoned)
                s = EntityRef.init;
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.spell1:
            me.castSpell(spell1);
            steps.after(step, 15.seconds);
            break;
        case Step.spell2:
            me.castSpell(spell2);
            steps.after(step, 15.seconds);
            break;
        case Step.summon:
            foreach (ref s; summoned)
                if (!s || !me.alive(s))
                {
                    s = me.summon(summonEntry, Location.init, 0, me.victim);
                    break;
                }
            steps.after(step, 15.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        draw(me);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptKind, ScriptRuntime;

    class FakeRuins : BlackHole!InstanceHost
    {
        Signal[] signals;
        EntityRef[] summoned, objects, objectsGone, zoned;
        int[] said;
        bool[ulong] dead;
        uint players = 1;
        override uint hostPlayerCount() { return players; }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override bool hostAlive(EntityRef who) { return (who.guid in dead) is null; }
        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(entry) << 24) | summoned.length);
            return summoned[$ - 1];
        }
        override EntityRef hostSummonObject(uint entry, Location, uint)
        {
            objects ~= EntityRef(0xF110_0000_0000_0100UL | (ulong(entry) << 24) | objects.length);
            return objects[$ - 1];
        }
        override ActionResult hostDespawnObject(EntityRef o) { objectsGone ~= o; return ActionResult.ok; }
        override ActionResult hostZoneCombat(EntityRef c) { zoned ~= c; return ActionResult.ok; }
        override ActionResult hostSay(EntityRef, int text, EntityRef) { said ~= text; return ActionResult.ok; }
        override size_t hostCreaturesNear(Location, uint entry, float, EntityRef[] into)
        {
            if (entry != npcQirajiWarrior || into.length < 2)
                return 0;
            into[0] = EntityRef(0xF130_0000_0000_0200UL | (ulong(entry) << 24) | zoned.length);
            into[1] = EntityRef(0xF130_0000_0000_0300UL | (ulong(entry) << 24) | zoned.length);
            return 2;
        }
    }

    EntityRef aqCreature(uint entry, uint spawn) { return EntityRef(0xF130_0000_0000_0000UL | (ulong(entry) << 24) | spawn); }
}

/// The Ruins' copy: Kurinnaxx slain brings Andorov and his four; the army's waves charge each in turn
/// (the next at once once one is beaten), Rajaxx last; a crystal used weakens Ossirian and another appears.
unittest
{
    import std.algorithm.searching : canFind, count;

    alias self = dmangos.scripts.ruinsofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto ruins = new FakeRuins;
    auto c = InstanceContext(ruins);
    auto h = runtime.create(ScriptKind.instance, "instance_ruins_of_ahnqiraj");
    const rajaxx = aqCreature(npcRajaxx, 1), ossirian = aqCreature(npcOssirian, 2);
    runtime.raise(h, c, CreatureLoaded(rajaxx));
    runtime.raise(h, c, CreatureLoaded(ossirian));
    foreach (i, captain; [npcCaptainQeez, npcCaptainTuubid, npcCaptainDrenn, npcCaptainXurrem, npcMajorYeggeth,
            npcMajorPakkon, npcColonelZerran])
        runtime.raise(h, c, CreatureLoaded(aqCreature(captain, cast(uint)(10 + i))));
    foreach (i; 0 .. 4)
        runtime.raise(h, c, CreatureLoaded(aqCreature(npcOssirianTrigger, 30 - i)));
    runtime.raise(h, c, PlayerEntered(EntityRef(7)));
    assert(ruins.objects.length == 1, "the first crystal, by the entrance");

    runtime.raise(h, c, CreatureDied(aqCreature(npcKurinnaxx, 3), EntityRef(7)));
    assert(ruins.summoned.length == 5 && ruins.summoned[0].entry == npcAndorov);

    // Andorov's words done: the first wave, its captain and his warriors.
    runtime.raise(h, c, Signal(ruins.summoned[0], Aq20Signal.startEvent, 0));
    assert(ruins.zoned.length == 3);
    // All of it slain: the next comes at the next look.
    foreach (z; ruins.zoned)
        ruins.dead[z.guid] = true;
    runtime.tick(h, c, 5000);
    assert(ruins.zoned.length == 6);
    // The rest by their three minutes each; Rajaxx last.
    foreach (_; 0 .. 6)
        runtime.tick(h, c, 180_000);
    assert(ruins.zoned[$ - 1] == rajaxx && ruins.said.canFind(RuinsOfAhnQiraj.sayRajaxxIntro));
    runtime.raise(h, c, CreatureDied(rajaxx, EntityRef(7)));
    assert(ruins.signals[$ - 1] == Signal(ruins.summoned[0], Aq20Signal.rajaxxDone, 0));

    // Ossirian: crystals at the start of his fight; one used weakens him and another appears.
    runtime.raise(h, c, Signal(ossirian, RuinsOfAhnQiraj.ossirianSpawnCrystals, 3));
    assert(ruins.objects.length == 4);
    runtime.raise(h, c, ObjectUsedHere(ruins.objects[1], EntityRef(7)));
    assert(ruins.signals[$ - 1].from == ossirian && ruins.signals[$ - 1].id == Aq20Signal.weakened);
    assert(ruins.objectsGone == [ruins.objects[1]] && ruins.objects.length == 5);
}

/**
 * The Ruins' copy after a worker's crash: Andorov and his Kaldorei, saved with the army's fight, wait for the raid
 * with its timers; the wave fighting then is the one under way, those beaten stay beaten, and the next follows it.
 * Ossirian's crystals are saved with his fight, and come back as his.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;

    static class FakeRuinsAfter : FakeRuins
    {
        uint[] killed;
        EntityRef[] fighting;
        override bool hostEntryKilled(uint entry) { return killed.canFind(entry); }
        override EntityRef hostVictimOf(EntityRef c) { return fighting.canFind(c) ? EntityRef(7) : EntityRef.init; }
        override EntityRef hostAnyPlayer() { return EntityRef(7); }
        override bool hostLocationOf(EntityRef who, out Location at)
        {
            at = Location(who.guid & 0xFFF, 0, 0); // each apart (the crystals far from the triggers)
            return true;
        }
    }

    alias self = dmangos.scripts.ruinsofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    const rajaxx = aqCreature(npcRajaxx, 1), ossirian = aqCreature(npcOssirian, 2);
    EntityRef[7] captains;
    foreach (i, entry; [npcCaptainQeez, npcCaptainTuubid, npcCaptainDrenn, npcCaptainXurrem, npcMajorYeggeth,
            npcMajorPakkon, npcColonelZerran])
        captains[i] = aqCreature(entry, cast(uint)(10 + i));
    void load(H)(H h, ref InstanceContext c)
    {
        runtime.raise(h, c, CreatureLoaded(rajaxx));
        runtime.raise(h, c, CreatureLoaded(ossirian));
        foreach (captain; captains)
            runtime.raise(h, c, CreatureLoaded(captain));
        foreach (i; 0 .. 4)
            runtime.raise(h, c, CreatureLoaded(aqCreature(npcOssirianTrigger, 30 - i)));
    }

    // The army under way: Andorov and his four saved with it; Ossirian's crystals saved with his fight.
    auto ruins = new FakeRuins;
    auto h = runtime.create(ScriptKind.instance, "instance_ruins_of_ahnqiraj");
    EntityRef[] allies;
    {
        auto c = InstanceContext(ruins);
        load(h, c);
        runtime.raise(h, c, PlayerEntered(EntityRef(7)));
        runtime.raise(h, c, CreatureDied(aqCreature(npcKurinnaxx, 3), EntityRef(7)));
        allies = ruins.summoned.dup;
        foreach (i, ally; allies)
            runtime.raise(h, c, CreatureLoaded(ally, true));
    }
    {
        auto c = InstanceContext(ruins);
        runtime.raise(h, c, Signal(allies[0], Aq20Signal.startEvent, 0));
        assert(c.checkpointSummons == allies && c.checkpointRequested, "Andorov and his four not saved with the army");
    }
    {
        auto c = InstanceContext(ruins);
        runtime.raise(h, c, CreatureEngaged(ossirian, EntityRef(7)));
        runtime.raise(h, c, Signal(ossirian, RuinsOfAhnQiraj.ossirianSpawnCrystals, 2));
        assert(c.checkpointSummons == ruins.objects[1 .. 3], "the crystals of his fight not saved with it");
    }
    {
        auto c = InstanceContext(ruins);
        runtime.raise(h, c, ObjectUsedHere(ruins.objects[1], EntityRef(7)));
        assert(c.releasedCheckpointActors == [ruins.objects[1]] && c.checkpointSummons == [ruins.objects[3]]);
    }
    ByteWriter saved;
    runtime.save(h, saved);

    // A worker's crash in the third wave: the first two captains slain, Captain Drenn and his warriors fighting.
    auto after = new FakeRuinsAfter;
    after.killed = [npcKurinnaxx, npcCaptainQeez, npcCaptainTuubid];
    auto h2 = runtime.create(ScriptKind.instance, "instance_ruins_of_ahnqiraj");
    auto reader = ByteReader(saved.data);
    assert(runtime.load(h2, reader));
    {
        auto c = InstanceContext(after);
        c.savedSummons = allies ~ ruins.objects[2 .. 4];
        runtime.raise(h2, c, Restored());
        assert(c.waitingForPlayer, "the army's timers do not wait for the raid");
    }
    {
        auto c = InstanceContext(after);
        load(h2, c);
        foreach (ally; allies)
            runtime.raise(h2, c, CreatureLoaded(ally, true));
        foreach (crystal; ruins.objects[2 .. 4])
            runtime.raise(h2, c, ObjectLoaded(crystal));
        assert(c.checkpointSummons == allies ~ ruins.objects[2 .. 4], "what came back not saved again");
        runtime.raise(h2, c, PlayerEntered(EntityRef(7)));
    }
    assert(!after.summoned.length, "another Andorov, his first back from the checkpoint");
    after.fighting = [captains[2], aqCreature(npcQirajiWarrior, 0x200), aqCreature(npcQirajiWarrior, 0x300)];
    {
        auto c = InstanceContext(after);
        runtime.tick(h2, c, 5000);
    }
    assert(!after.zoned.length && !after.said.length, "a wave sent while the third fights on");
    after.dead[captains[2].guid] = true;
    after.dead[aqCreature(npcQirajiWarrior, 0x200).guid] = true;
    after.dead[aqCreature(npcQirajiWarrior, 0x300).guid] = true;
    {
        auto c = InstanceContext(after);
        runtime.tick(h2, c, 5000);
    }
    assert(after.zoned.length && after.zoned[0] == captains[3] && after.said == [-1_509_006],
        "the fourth wave not next after the third");

    // Used after the crash, a crystal of his fight weakens him, and is no longer saved.
    {
        auto c = InstanceContext(after);
        runtime.raise(h2, c, ObjectUsedHere(ruins.objects[2], EntityRef(7)));
        assert(after.signals[$ - 1] == Signal(ossirian, Aq20Signal.weakened, after.signals[$ - 1].value));
        assert(c.releasedCheckpointActors == [ruins.objects[2]]);
    }

    // Rajaxx's death saved, the checkpoint after it lost: the army is beaten, and Andorov (back) trades.
    auto beaten = new FakeRuinsAfter;
    beaten.killed = [npcKurinnaxx, npcRajaxx];
    auto h3 = runtime.create(ScriptKind.instance, "instance_ruins_of_ahnqiraj");
    reader = ByteReader(saved.data);
    assert(runtime.load(h3, reader));
    {
        auto c = InstanceContext(beaten);
        c.savedSummons = allies;
        runtime.raise(h3, c, Restored());
        runtime.raise(h3, c, CreatureLoaded(allies[0], true));
        runtime.raise(h3, c, PlayerEntered(EntityRef(7)));
        runtime.raise(h3, c, Asked(EntityRef.init, Aq20Encounter.rajaxx));
        assert(c.answerGiven == EncounterState.done);
    }
    assert(beaten.signals.canFind(Signal(allies[0], Aq20Signal.rajaxxDone, 0)) && !beaten.summoned.length);
}
