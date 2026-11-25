/**
 * Uldaman (map 70): the Altar of the Keepers (used, it wakes the Stone Keepers one at a time; with
 * all of them dead the temple doors open, and stay open), and Archaedas, woken at his altar, who
 * wakes the earthen dwarves, his guardians and at last the vault warders against the players; his
 * death opens the Ancient Vault and brings its treasure.
 */
module dmangos.scripts.uldaman;

import dmangos.script;

/// Creatures and objects of Uldaman.
enum : uint
{
    archaedas = 2748,
    custodian = 7309,
    hallshaper = 7077,
    earthenGuardian = 7076,
    vaultWarder = 10120,
    stoneKeeper = 4857,

    templeDoorUpper = 124367,
    templeDoorLower = 141869,
    ancientVault = 124369,
    ancientTreasure = 141979,
}

/// The altars' events (`scripted_event_id`: event_spell_altar_boss_aggro).
enum : uint { keepersAltar = 2228, archaedasAltar = 2268 }

/// The stone skin that holds the statues still.
enum uint stoned = 10255;

/// An encounter's state, as Uldaman's script tracks it.
enum Fight : ubyte { notStarted, inProgress, waking, done, failed }

/// What Uldaman remembers (`instance.data`).
@instance("instance_uldaman")
struct Uldaman
{
    /// Signals from Archaedas: he fights, gave up, wakes his guardians, his warders, a dwarf.
    enum Signals : uint { engaged = 100, evaded = 101, wakeGuardians = 102, wakeWarders = 103, wakeDwarf = 104 }

    Fight keepers, archaedasFight;
    EntityRef starter;            /// who used the altar
    Pack!8 keeperPack;
    bool[8] keeperWoken;
    Pack!64 dwarves;              /// custodians and hallshapers
    Pack!8 guardians, warders;
    @transient EntityRef upper, lower, vault, archaedasRef;
    @transient bool keepersRecovering, archaedasRecovering;

    enum Step : ubyte { wakeKeeper }
    Schedule!Step steps;

    void on(ref InstanceContext ulda, const ref Restored e)
    {
        if (keepers == Fight.inProgress)
        {
            bool captured = steps.pending(Step.wakeKeeper);
            foreach (who; keeperPack)
                captured |= ulda.hasSavedCreature(who);
            if (captured)
            {
                keepersRecovering = true;
                ulda.waitForPlayer();
            }
            else
                keepers = Fight.notStarted; // legacy saves omitted the awake creature
        }
        if (archaedasFight == Fight.inProgress || archaedasFight == Fight.waking)
        {
            archaedasRecovering = ulda.hasSavedCreature(archaedas);
            if (archaedasRecovering)
                ulda.waitForPlayer();
            else
                archaedasFight = Fight.notStarted;
        }
    }

    void on(ref InstanceContext ulda, const ref PlayerEntered e)
    {
        if (archaedasRecovering)
        {
            archaedasRecovering = false;
            if (!ulda.alive(starter))
                starter = e.player;
            if (archaedasFight == Fight.inProgress && archaedasRef && !ulda.alive(ulda.victimOf(archaedasRef)))
                ulda.attack(archaedasRef, starter);
        }
        if (!keepersRecovering)
            return;
        keepersRecovering = false;
        if (!ulda.alive(starter))
            starter = e.player;
        bool waking;
        foreach (who; keeperPack)
        {
            const index = keeperPack.indexOf(who);
            if (!keeperWoken[index])
                continue;
            if (!ulda.alive(who))
                continue;
            waking = true;
            if (!ulda.alive(ulda.victimOf(who)))
                ulda.attack(who, starter);
        }
        if (!waking && !steps.pending(Step.wakeKeeper))
            steps.after(Step.wakeKeeper, 5.seconds);
    }

    void on(ref InstanceContext ulda, const ref ObjectLoaded e)
    {
        switch (e.object.entry)
        {
        case templeDoorUpper:
            upper = e.object;
            if (keepers == Fight.done)
                ulda.door(e.object, true);
            break;
        case templeDoorLower:
            lower = e.object;
            if (keepers == Fight.done)
                ulda.door(e.object, true);
            break;
        case ancientVault:
            vault = e.object;
            if (archaedasFight == Fight.done)
                ulda.door(e.object, true);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext ulda, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case stoneKeeper: keeperPack.add(e.creature); break;
        case custodian, hallshaper: dwarves.add(e.creature); break;
        case earthenGuardian: guardians.add(e.creature); break;
        case vaultWarder: warders.add(e.creature); break;
        case archaedas: archaedasRef = e.creature; break;
        default: break;
        }
    }

    void on(ref InstanceContext ulda, const ref EventHappened e)
    {
        if (e.event == keepersAltar && (keepers == Fight.notStarted || keepers == Fight.failed))
        {
            resetKeepers(ulda);
            starter = e.source;
            keepers = Fight.inProgress;
            steps.after(Step.wakeKeeper, 5.seconds);
            ulda.checkpoint();
        }
        else if (e.event == archaedasAltar
            && (archaedasFight == Fight.notStarted || archaedasFight == Fight.failed) && archaedasRef)
        {
            starter = e.source;
            archaedasFight = Fight.waking;
            ulda.signal(archaedasRef, Archaedas.Signals.wake);
            ulda.checkpointCreature(archaedasRef);
        }
    }

    /// The next Stone Keeper sheds its stone skin and attacks.
    void on(ref InstanceContext ulda, Step step)
    {
        if (keepers != Fight.inProgress)
            return;
        foreach (keeper; keeperPack)
        {
            const index = keeperPack.indexOf(keeper);
            if (!keeperWoken[index])
            {
                if (!ulda.alive(starter))
                {
                    resetKeepers(ulda);
                    return;
                }
                keeperWoken[index] = true;
                ulda.removeAura(keeper, stoned);
                ulda.attack(keeper, starter);
                ulda.checkpointCreature(keeper);
                return;
            }
        }
    }

    void on(ref InstanceContext ulda, const ref CreatureDied e)
    {
        dwarves.died(e.creature);
        guardians.died(e.creature);
        warders.died(e.creature);
        if (e.creature.entry == stoneKeeper && keeperPack.died(e.creature) && keepers == Fight.inProgress)
        {
            if (keeperPack.allDead)
            {
                keepers = Fight.done;
                ulda.log("the Stone Keepers have fallen: the temple doors open");
                foreach (door; [upper, lower])
                    if (door)
                        ulda.door(door, true);
            }
            else
                steps.after(Step.wakeKeeper, 5.seconds);
            ulda.checkpoint();
        }
        else if (e.creature.entry == archaedas)
        {
            archaedasFight = Fight.done;
            if (vault)
                ulda.door(vault, true);
            ulda.spawnObjects(ancientTreasure, 3600);
            ulda.checkpoint();
        }
    }

    void on(ref InstanceContext ulda, const ref CreatureEvaded e)
    {
        if (e.creature.entry == stoneKeeper && keepers == Fight.inProgress)
            resetKeepers(ulda);
    }

    private void resetKeepers(ref InstanceContext ulda)
    {
        keepers = Fight.failed;
        steps.clear();
        keeperWoken[] = false;
        keeperPack.reviveAll();
        ulda.respawnKilled(stoneKeeper);
        foreach (keeper; keeperPack)
            if (ulda.alive(keeper) && !ulda.hasAura(keeper, stoned))
                ulda.castSpell(keeper, stoned);
        ulda.checkpoint();
    }

    void on(ref InstanceContext ulda, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.engaged:
            archaedasFight = Fight.inProgress;
            if (archaedasRef)
                ulda.checkpointCreature(archaedasRef);
            break;
        case Signals.evaded:
            if (archaedasFight != Fight.done)
                archaedasFight = Fight.failed;
            break;
        case Signals.wakeGuardians:
            foreach (who; guardians)
                wake(ulda, who);
            break;
        case Signals.wakeWarders:
            foreach (who; warders)
                wake(ulda, who);
            break;
        case Signals.wakeDwarf:
            Location boss;
            if (!ulda.locationOf(archaedasRef, boss))
                break;
            EntityRef nearest;
            float nearestDistance = float.infinity;
            foreach (who; dwarves)
            {
                Location at;
                if (!ulda.hasAura(who, stoned) || !ulda.locationOf(who, at))
                    continue;
                const distance = (at.x - boss.x) ^^ 2 + (at.y - boss.y) ^^ 2 + (at.z - boss.z) ^^ 2;
                if (distance < nearestDistance)
                {
                    nearest = who;
                    nearestDistance = distance;
                }
            }
            if (nearest)
                wake(ulda, nearest);
            break;
        default:
            break;
        }
    }

    /// A statue sheds its stone skin and goes for whom Archaedas fights.
    private void wake(ref InstanceContext ulda, EntityRef who)
    {
        ulda.removeAura(who, stoned);
        const target = archaedasRef ? ulda.victimOf(archaedasRef) : EntityRef.init;
        ulda.attack(who, target ? target : starter);
        ulda.checkpointCreature(who);
    }
}

/**
 * Archaedas: frozen until his altar is used; he breaks free and goes for the one who used it. He
 * shakes the ground, wakes the earthen dwarves one by one while above a third of his health, his
 * guardians at two thirds and his vault warders at one third.
 */
@creature("boss_archaedas")
struct Archaedas
{
    enum Signals : uint { wake = 1 }
    enum : uint
    {
        awakenVisual = 10347, groundTremor = 6524, awakenGuardians = 10252, awakenWarders = 10258,
        awakenDwarf = 10259, freezeAnim = 16245,
    }
    enum : int { sayAggro = -1070001, sayGuardians = -1070002, sayWarders = -1070003, saySlain = -1070004, emoteFree = -1070005 }

    enum Step : ubyte { visual, breaksFree, attack, tremor, dwarf }
    Schedule!Step steps;
    ubyte hpPhase = 1;
    bool dwarvesDone, awake;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        freeze(me);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.wake && !awake)
            steps.after(Step.visual, 1.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.tremor, (7000 + me.random(7000)).msecs);
        steps.after(Step.dwarf, 10.seconds);
        me.signalDungeon(Uldaman.Signals.engaged);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (hpPhase <= 2 && e.after < 100 - 33.4f * hpPhase)
        {
            const guardiansNow = hpPhase == 1;
            me.castSelf(guardiansNow ? awakenGuardians : awakenWarders);
            me.say(guardiansNow ? sayGuardians : sayWarders);
            me.signalDungeon(guardiansNow ? Uldaman.Signals.wakeGuardians : Uldaman.Signals.wakeWarders);
            ++hpPhase;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.visual:
            me.castSelf(awakenVisual);
            steps.after(Step.breaksFree, 2.seconds);
            break;
        case Step.breaksFree:
            me.say(emoteFree);
            steps.after(Step.attack, 3.seconds);
            break;
        case Step.attack:
            awake = true;
            me.say(sayAggro);
            me.removeAura(me.self, freezeAnim);
            me.unitFlags(UnitFlag.uninteractible, false);
            if (const enemy = me.playerNearby(80))
                me.attack(enemy);
            break;
        case Step.tremor:
            me.castSelf(groundTremor);
            steps.after(Step.tremor, (8000 + me.random(9000)).msecs);
            break;
        case Step.dwarf:
            if (dwarvesDone || me.healthPercent < 33)
                break;
            me.castSelf(awakenDwarf);
            me.signalDungeon(Uldaman.Signals.wakeDwarf);
            steps.after(Step.dwarf, (9000 + me.random(3000)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.say(saySlain);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        me.signalDungeon(Uldaman.Signals.evaded);
        freeze(me);
    }

    private void freeze(ref CreatureContext me)
    {
        steps.clear();
        hpPhase = 1;
        awake = dwarvesDone = false;
        me.castSelf(freezeAnim, true);
        me.unitFlags(UnitFlag.uninteractible);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// An altar of Uldaman used (`event_spell_altar_boss_aggro`): the dungeon's script wakes the Stone Keepers or
/// Archaedas (`EventHappened`); the event's own script lets it through to it.
@scriptedEvent("event_spell_altar_boss_aggro")
struct UldamanAltarEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.uldaman;
    auto ulda = runInstance!self("instance_uldaman");
    ulda.raise(ObjectLoaded(objectRef(templeDoorUpper)));
    ulda.raise(ObjectLoaded(objectRef(templeDoorLower)));
    foreach (spawn; 1 .. 5)
        ulda.raise(CreatureLoaded(creatureRef(stoneKeeper, spawn)));
    ulda.raise(EventHappened(keepersAltar, playerRef, objectRef(1)));
    ulda.run(5000);
    assert(ulda.host.times("unaura 4857 10255") == 1 && ulda.host.times("attack 4857") == 1);
    foreach (spawn; 1 .. 4)
    {
        ulda.raise(CreatureDied(creatureRef(stoneKeeper, spawn)));
        ulda.run(5000);
    }
    assert(ulda.host.times("attack 4857") == 4, "one after another");
    assert(!ulda.host.done("door 124367 open"));
    ulda.raise(CreatureDied(creatureRef(stoneKeeper, 4)));
    assert(ulda.host.done("door 124367 open") && ulda.host.done("door 141869 open"));

    // Archaedas's altar wakes him; his signals wake his statues.
    ulda.raise(CreatureLoaded(creatureRef(archaedas)));
    foreach (spawn; 1 .. 4)
        ulda.raise(CreatureLoaded(creatureRef(earthenGuardian, spawn)));
    ulda.raise(EventHappened(archaedasAltar, playerRef, objectRef(2)));
    assert(ulda.host.done("signal 2748 1 0"));
    ulda.raise(Signal(creatureRef(archaedas), Uldaman.Signals.wakeGuardians));
    assert(ulda.host.times("attack 7076") == 3);
    ulda.raise(CreatureDied(creatureRef(archaedas)));
    assert(ulda.host.done("spawn objects 141979"));

    auto boss = runCreature!self("boss_archaedas", archaedas);
    boss.raise(Spawned());
    assert(boss.host.done("cast 16245"));
    boss.raise(Signal(EntityRef.init, Archaedas.Signals.wake));
    boss.run(7000);
    assert(boss.host.done("say -1070005") && boss.host.done("attack") && boss.host.done("unaura 16245"));
    boss.raise(Damaged(playerRef, 10, 70, 60));
    assert(boss.host.done("dungeon 102 0"));
    boss.raise(Damaged(playerRef, 10, 40, 30));
    assert(boss.host.done("dungeon 103 0"));
}
