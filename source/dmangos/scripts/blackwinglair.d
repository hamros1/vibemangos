/**
 * Blackwing Lair (map 469): the copy's script (its encounters and doors, Razorgore's room with its
 * dragon eggs and the defenders pouring from the generators, the breaths Chromaggus has this copy and the
 * drakonids of Nefarian's tunnels, Nefarian's arrival), the area trigger where Vaelastrasz is corrupted,
 * and the bosses: Razorgore the Untamed, Vaelastrasz the Corrupt, Broodlord Lashlayer, Firemaw, Ebonroc,
 * Flamegor, Chromaggus, Lord Victor Nefarius and Nefarian.
 *
 * Razorgore's eggs are destroyed here by players using them (the core cannot let a player possess
 * Razorgore through the Orb of Domination, as the original fight has it): with every egg broken the
 * defenders flee and Razorgore fights.
 */
module dmangos.scripts.blackwinglair;

import core.time : Duration;

import dmangos.script;

/// The copy's encounters (CMaNGOS's `TYPE_*`).
enum BwlEncounter : ubyte
{
    razorgore,
    vaelastrasz,
    lashlayer,
    firemaw,
    ebonroc,
    flamegor,
    chromaggus,
    nefarian,
}

/// Questions the copy answers beyond the encounters.
enum BwlQuestion : uint
{
    chromaLeftBreath = 9,
    chromaRightBreath = 10,
}

/// Creatures and objects of the copy.
enum : uint
{
    npcRazorgore = 12435,
    npcVaelastrasz = 13020,
    npcLashlayer = 12017,
    npcChromaggus = 14020,
    npcNefarian = 11583,
    npcVictorNefarius = 10162,
    npcGrethok = 12557,
    npcNefariansTroops = 14459,
    npcMonsterGenerator = 12434,
    npcLegionnaire = 12416,
    npcMage = 12420,
    npcDragonspawn = 12422,

    goDoorRazorgoreEnter = 176964,
    goDoorRazorgoreExit = 176965,
    goDoorNefarian = 176966,
    goDoorChromaggusExit = 179117,
    goDoorVaelastrasz = 179364,
    goDoorLashlayer = 179365,
    goBlackDragonEgg = 177807,
    goSuppressionDevice = 179784,
}

/// The drakonid spawners of Nefarian's tunnels, and the drakonids.
private static immutable uint[5] spawners = [14307, 14309, 14310, 14311, 14312];
private static immutable uint[6] drakonids = [14261, 14262, 14263, 14264, 14265, 14302];
/// Chromaggus' breaths, left and right: Frost Burn, Incinerate, Time Lapse, Corrosive Acid, Ignite Flesh.
private static immutable uint[5] leftBreaths = [23187, 23308, 23310, 23313, 23315];
private static immutable uint[5] rightBreaths = [23189, 23309, 23312, 23314, 23316];

private static immutable Location[3] nefarianLocs = [
    Location(-7599.32f, -1191.72f, 475.545f, 5.0f), // the tunnel openings
    Location(-7526.27f, -1135.04f, 473.445f, 5.0f),
    Location(-7348.849f, -1495.134f, 552.5152f, 1.798f), // where Nefarian comes from
];
private static immutable nefariusAtThrone = Location(-7466.16f, -1040.80f, 412.053f, 2.14675f);

/// What scripts of the copy say to each other, beyond the encounters' states (ids 0 .. 7).
enum BwlSignal : uint
{
    eggsBroken = 100,   /// the copy to Razorgore: every egg is broken; fight
    vaelIntro = 101,    /// the copy to Vaelastrasz: players came near
    vaelTrigger = 102,  /// the area trigger to the copy
    nefariusLine = 103, /// Vaelastrasz to his Nefarius: say line `value`
}

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/// What the copy remembers: its encounters, and the breaths and drakonids it drew (saved in `instance.data`).
@instance("instance_blackwing_lair")
struct BlackwingLair
{
    enum : int
    {
        emoteOrbShutOff = -1_469_035,
        emoteTroopsFlee = -1_469_033,
        sayRazorgoreDeath = -1_469_025,
        sayEggsBroken1 = -1_469_022,
    }
    enum ubyte maxEggDefenders = 4, maxDragonspawn = 12, maxBlackwingDefenders = 40, drakonidsToSlay = 42;

    EncounterState[BwlEncounter.max + 1] encounters;
    uint leftBreath, rightBreath, leftTunnel, rightTunnel;
    ushort eggsBroken;

    @transient EntityRef razorgore, vaelastrasz, nefarius, troops;
    @transient EntityRef[6] doors; /// enter, exit, Nefarian, Chromaggus' exit, Vaelastrasz', Lashlayer's
    @transient EntityRef[8] generators;
    @transient ubyte generatorCount;
    @transient ushort eggs;
    @transient EntityRef[64] defenders;
    @transient ubyte dragonspawn, blackwingDefenders;
    @transient EntityRef[2] tunnelSpawners;
    @transient EntityRef[48] drakonidsSeen;
    @transient ubyte drakonidsSlain;
    @transient EntityRef[4] eggsToGo;

    enum Step : ubyte { defense, nefarian, eggsGone }
    Schedule!Step steps;

    private static immutable uint[6] doorEntries = [goDoorRazorgoreEnter, goDoorRazorgoreExit, goDoorNefarian,
        goDoorChromaggusExit, goDoorVaelastrasz, goDoorLashlayer];

    /// `who` among `those` (once), if there is room.
    private static void remember(EntityRef[] those, EntityRef who)
    {
        foreach (ref t; those)
            if (t == who)
                return;
        foreach (ref t; those)
            if (!t)
            {
                t = who;
                return;
            }
    }

    /// Whether door `i` stands open now.
    private bool doorOpen(size_t i) const
    {
        final switch (i)
        {
        case 0: // the main gate: shut while any encounter before Nefarian is under way
            foreach (e; encounters[0 .. BwlEncounter.nefarian])
                if (e == EncounterState.inProgress || e == EncounterState.special)
                    return false;
            return true;
        case 1:
            return encounters[BwlEncounter.razorgore] == EncounterState.done;
        case 2:
            return encounters[BwlEncounter.nefarian] != EncounterState.inProgress
                && encounters[BwlEncounter.nefarian] != EncounterState.special;
        case 3:
            return encounters[BwlEncounter.chromaggus] == EncounterState.done;
        case 4:
            return encounters[BwlEncounter.vaelastrasz] == EncounterState.done;
        case 5:
            return encounters[BwlEncounter.lashlayer] == EncounterState.done;
        }
    }

    private void updateDoors(ref InstanceContext copy)
    {
        foreach (i, d; doors)
            if (d)
                copy.door(d, doorOpen(i));
    }

    /// The breaths and tunnels this copy has, drawn once.
    private void draw(ref InstanceContext copy)
    {
        import std.random : uniform, Random, unpredictableSeed;

        if (leftBreath)
            return;
        auto rng = Random(unpredictableSeed);
        leftBreath = leftBreaths[uniform(0, 5, rng)];
        rightBreath = rightBreaths[uniform(0, 5, rng)];
        leftTunnel = spawners[uniform(0, 5, rng)];
        rightTunnel = spawners[uniform(0, 5, rng)];
    }

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        draw(copy);
        switch (e.creature.entry)
        {
        case npcRazorgore:
            razorgore = e.creature;
            break;
        case npcVaelastrasz:
            vaelastrasz = e.creature;
            break;
        case npcVictorNefarius:
            if (!nefarius)
                nefarius = e.creature;
            break;
        case npcNefariansTroops:
            troops = e.creature;
            break;
        case npcMonsterGenerator:
            if (generatorCount < generators.length)
                generators[generatorCount++] = e.creature;
            break;
        case npcLegionnaire, npcMage, npcDragonspawn:
            if (encounters[BwlEncounter.razorgore] == EncounterState.inProgress)
                remember(defenders[], e.creature);
            break;
        default:
            foreach (entry; drakonids)
                if (e.creature.entry == entry)
                    remember(drakonidsSeen[], e.creature);
            break;
        }
    }

    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        draw(copy);
        foreach (i, entry; doorEntries)
            if (e.object.entry == entry)
            {
                doors[i] = e.object;
                copy.door(e.object, doorOpen(i));
            }
        if (e.object.entry == goBlackDragonEgg)
            ++eggs;
        if (e.object.entry == goSuppressionDevice && encounters[BwlEncounter.lashlayer] == EncounterState.done)
            copy.despawnObject(e.object);
    }

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id <= BwlEncounter.max)
            copy.answer(encounters[e.id]);
        else if (e.id == BwlQuestion.chromaLeftBreath)
            copy.answer(leftBreath);
        else if (e.id == BwlQuestion.chromaRightBreath)
            copy.answer(rightBreath);
    }

    void on(ref InstanceContext copy, const ref CreatureEngaged e)
    {
        // Grethok the Controller attacked: Razorgore's room wakes.
        if (e.creature.entry == npcGrethok && encounters[BwlEncounter.razorgore] != EncounterState.done
                && encounters[BwlEncounter.razorgore] != EncounterState.special)
        {
            set(copy, BwlEncounter.razorgore, EncounterState.inProgress);
            steps.after(Step.defense, 40.seconds);
        }
    }

    void on(ref InstanceContext copy, const ref ObjectUsedHere e)
    {
        if (e.object.entry != goBlackDragonEgg || encounters[BwlEncounter.razorgore] != EncounterState.inProgress)
            return;
        ++eggsBroken;
        if (razorgore && copy.random(2))
            copy.say(razorgore, sayEggsBroken1 - copy.random(3));
        foreach (ref g; eggsToGo)
            if (!g)
            {
                g = e.object;
                break;
            }
        steps.after(Step.eggsGone, 0.msecs); // once the use is over
        if (eggsBroken >= eggs && eggs)
            allEggsBroken(copy);
    }

    /// The last egg broken: the orb goes dark, the defenders flee, and Razorgore fights.
    private void allEggsBroken(ref InstanceContext copy)
    {
        set(copy, BwlEncounter.razorgore, EncounterState.special);
        steps.cancel(Step.defense);
        if (troops)
        {
            copy.say(troops, emoteOrbShutOff);
            copy.say(troops, emoteTroopsFlee);
        }
        if (razorgore)
            copy.signal(razorgore, BwlSignal.eggsBroken);
        foreach (ref d; defenders)
            if (d)
            {
                copy.despawn(d, 10_000);
                d = EntityRef.init;
            }
        dragonspawn = blackwingDefenders = 0;
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case npcRazorgore:
            if (encounters[BwlEncounter.razorgore] == EncounterState.special)
                set(copy, BwlEncounter.razorgore, EncounterState.done);
            break;
        case npcLegionnaire, npcMage:
            if (blackwingDefenders)
                --blackwingDefenders;
            break;
        case npcDragonspawn:
            if (dragonspawn)
                --dragonspawn;
            break;
        default:
            foreach (entry; drakonids)
                if (e.creature.entry == entry && ++drakonidsSlain >= drakonidsToSlay
                        && encounters[BwlEncounter.nefarian] == EncounterState.inProgress)
                {
                    set(copy, BwlEncounter.nefarian, EncounterState.special);
                    foreach (ref s; tunnelSpawners)
                        if (s)
                        {
                            copy.despawn(s);
                            s = EntityRef.init;
                        }
                    steps.after(Step.nefarian, 5.seconds);
                }
            break;
        }
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id == BwlSignal.vaelTrigger)
        {
            if (encounters[BwlEncounter.vaelastrasz] == EncounterState.notStarted && vaelastrasz)
            {
                encounters[BwlEncounter.vaelastrasz] = EncounterState.special;
                copy.signal(vaelastrasz, BwlSignal.vaelIntro);
            }
            return;
        }
        if (e.id > BwlEncounter.max)
            return;
        set(copy, cast(BwlEncounter) e.id, cast(EncounterState) e.value);
    }

    /// An encounter's new state, and what follows from it.
    private void set(ref InstanceContext copy, BwlEncounter which, EncounterState state)
    {
        const was = encounters[which];
        encounters[which] = state;
        final switch (which)
        {
        case BwlEncounter.razorgore:
            if (state == EncounterState.failed)
            {
                steps.cancel(Step.defense);
                foreach (ref d; defenders)
                    if (d)
                    {
                        copy.despawn(d);
                        d = EntityRef.init;
                    }
                dragonspawn = blackwingDefenders = 0;
                if (razorgore)
                    copy.say(razorgore, sayRazorgoreDeath);
            }
            break;
        case BwlEncounter.nefarian:
            if (state == EncounterState.inProgress && was != EncounterState.inProgress && nefarius)
            {
                drakonidsSlain = 0;
                tunnelSpawners[0] = copy.summon(leftTunnel, nefarianLocs[0], 3600 * 1000);
                tunnelSpawners[1] = copy.summon(rightTunnel, nefarianLocs[1], 3600 * 1000);
            }
            if (state == EncounterState.failed)
                cleanupNefarian(copy);
            break;
        case BwlEncounter.vaelastrasz, BwlEncounter.lashlayer, BwlEncounter.firemaw, BwlEncounter.ebonroc,
                BwlEncounter.flamegor, BwlEncounter.chromaggus:
            break;
        }
        updateDoors(copy);
    }

    /// Nefarius' stage cleared after a wipe: his drakonids and spawners gone.
    private void cleanupNefarian(ref InstanceContext copy)
    {
        steps.cancel(Step.nefarian);
        foreach (ref s; tunnelSpawners)
            if (s)
            {
                copy.despawn(s);
                s = EntityRef.init;
            }
        foreach (ref d; drakonidsSeen)
            if (d)
            {
                if (copy.alive(d))
                    copy.despawn(d);
                d = EntityRef.init;
            }
        drakonidsSlain = 0;
    }

    void on(ref InstanceContext copy, Step step)
    {
        final switch (step)
        {
        case Step.defense:
            defend(copy);
            steps.after(Step.defense, 15.seconds);
            break;
        case Step.nefarian:
            // Nefarian comes; Nefarius blinks away.
            const nefarian = copy.summon(npcNefarian, nefarianLocs[2], 0);
            if (nefarius && copy.alive(nefarius))
            {
                copy.castAs(nefarius, 22_681, nefarius); // Shadowblink
                copy.despawn(nefarius, 2500);
            }
            if (nefarian)
                copy.log("Nefarian comes");
            break;
        case Step.eggsGone:
            foreach (ref g; eggsToGo)
                if (g)
                {
                    copy.despawnObject(g);
                    g = EntityRef.init;
                }
            break;
        }
    }

    /// Four generators at random send a defender each.
    private void defend(ref InstanceContext copy)
    {
        if (generatorCount == 0)
            return;
        foreach (_; 0 .. maxEggDefenders)
        {
            const generator = generators[copy.random(generatorCount)];
            uint entry;
            switch (copy.random(dragonspawn < maxDragonspawn ? 4 : 2))
            {
            case 0:
                if (blackwingDefenders < maxBlackwingDefenders)
                    entry = npcLegionnaire;
                break;
            case 1:
                if (blackwingDefenders < maxBlackwingDefenders)
                    entry = npcMage;
                break;
            default:
                entry = npcDragonspawn;
                break;
            }
            if (!entry)
                continue;
            const made = copy.summon(entry, copy.locationOf(generator), 0);
            if (!made)
                continue;
            remember(defenders[], made);
            if (entry == npcDragonspawn)
                ++dragonspawn;
            else
                ++blackwingDefenders;
            copy.zoneCombat(made);
        }
    }
}

/// Where players come near Vaelastrasz: Nefarius corrupts him (once a copy).
@areaTrigger("at_vaelastrasz")
struct AtVaelastrasz
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (e.trigger == 3626)
            at.signalDungeon(BwlSignal.vaelTrigger);
    }
}

/// What every boss of the copy shares: its encounter under way, failed (home again), done.
private enum encounterOf(string which) = `
    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(` ~ which ~ `, EncounterState.done);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.signalDungeon(` ~ which ~ `, EncounterState.failed);
        static if (__traits(hasMember, typeof(this), "reset"))
            reset(me);
    }
`;

/**
 * Razorgore the Untamed: cannot die while an egg is whole (a "death" then is the copy's failure); once
 * every egg is broken he is healed, and fought: Conflagration, Fireball Volley, War Stomp, Cleave.
 */
@creature("boss_razorgore")
struct Razorgore
{
    enum : uint
    {
        possessVisual = 23014,
        cleave = 19632,
        warStomp = 24375,
        fireballVolley = 22425,
        conflagration = 23023,
        doubleAttack = 18943,
        warmingFlames = 23040,
        fireball = 23024,
    }
    enum Step : ubyte { conflagration, volley, stomp, cleave }
    Schedule!Step steps;
    bool free;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        reset(me);
    }

    void reset(ref CreatureContext me)
    {
        free = me.askDungeon(BwlEncounter.razorgore) == EncounterState.special;
        me.deathPrevention(!free);
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.removeAura(me.self, possessVisual);
        steps.after(Step.conflagration, between(me, 10_000, 15_000));
        steps.after(Step.volley, between(me, 15_000, 20_000));
        steps.after(Step.stomp, 30.seconds);
        steps.after(Step.cleave, between(me, 4000, 8000));
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != BwlSignal.eggsBroken)
            return;
        free = true;
        me.deathPrevention(false);
        me.melee(true);
        me.removeAura(me.self, possessVisual);
        me.castSelf(warmingFlames, true);
        me.setHealthPercent(100);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        // Brought down before his eggs are broken: the room has failed; he burns everyone.
        if (!free && e.after == 0)
        {
            me.signalDungeon(BwlEncounter.razorgore, EncounterState.failed);
            me.castSelf(fireball, true);
            me.evade();
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.conflagration:
            steps.after(step, me.castSelf(conflagration) == ActionResult.ok ? between(me, 15_000, 25_000) : retry);
            break;
        case Step.volley:
            steps.after(step, me.castSelf(fireballVolley) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.stomp:
            steps.after(step, me.castSelf(warStomp) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.cleave:
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? between(me, 4000, 8000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (me.askDungeon(BwlEncounter.razorgore) == EncounterState.inProgress)
            me.signalDungeon(BwlEncounter.razorgore, EncounterState.failed);
        reset(me);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// The Blackwing orb trigger: its glow while Grethok controls the orb (looks only).
@creature("npc_blackwing_orb")
struct BlackwingOrb
{
    enum uint possessVisual = 23014, controlOrb = 23018;
    enum Step : ubyte { visual }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.after(Step.visual, 4.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        EntityRef[1] grethok;
        if (me.creaturesNear(npcGrethok, 10, grethok[]))
        {
            me.castSelf(possessVisual, true);
            me.castAs(grethok[0], controlOrb, grethok[0], true);
        }
        else
            steps.after(step, 2.seconds);
    }
}

/**
 * Vaelastrasz the Corrupt: lying at a third of his health until Nefarius corrupts him as players come
 * near; spoken to, he begs to be released and turns on them: Essence of the Red, Burning Adrenaline,
 * Flame Breath, Fire Nova, Cleave, Tail Sweep.
 */
@creature("boss_vaelastrasz")
struct Vaelastrasz
{
    enum : int
    {
        sayLine1 = -1_469_026,
        sayLine2 = -1_469_027,
        sayLine3 = -1_469_028,
        sayHalflife = -1_469_029,
        sayKillTarget = -1_469_030,
        sayNefariusCorrupt1 = -1_469_006,
        sayNefariusCorrupt2 = -1_469_032,
    }
    enum : uint
    {
        essenceOfTheRed = 23513,
        flameBreath = 23461,
        fireNova = 23462,
        tailSweep = 15847,
        burningAdrenalineTank = 18173,
        burningAdrenaline = 23620,
        cleave = 19983,
        nefariusCorruption = 23642,
        redLightning = 19484,
    }
    enum : uint { textVael1 = 7156, textVael2 = 7256 }
    enum uint factionHostile = 14;
    enum : uint { npcFlagGossip = 1, npcFlagQuestGiver = 2 }

    enum Step : ubyte { intro, speech, adrenalineTank, adrenaline, breath, nova, cleave, tailSweep }
    Schedule!Step steps;
    ubyte introPhase, speechNum;
    bool lowYelled;
    EntityRef nefarius;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.setHealthPercent(30);
        me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == BwlSignal.vaelIntro)
        {
            introPhase = 0;
            steps.after(Step.intro, 1.seconds);
        }
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        GossipMenu menu;
        menu.add(GossipIcon.chat, "I cannot, Vaelastrasz! Surely something can be done to heal you!", 1);
        me.sendGossip(e.player, textVael1, menu);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.consume();
        if (e.action == 1)
        {
            GossipMenu menu;
            menu.add(GossipIcon.chat, "Vaelastrasz, no!!!", 2);
            me.sendGossip(e.player, textVael2, menu, false);
        }
        else if (e.action == 2)
        {
            me.closeGossip(e.player);
            me.npcFlags(0);
            me.say(sayLine1);
            me.standState(StandState.stand);
            speechNum = 0;
            steps.after(Step.speech, 10.seconds);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(BwlEncounter.vaelastrasz, EncounterState.inProgress);
        me.castSelf(essenceOfTheRed);
        steps.after(Step.adrenalineTank, 45.seconds);
        steps.after(Step.adrenaline, 15.seconds);
        steps.after(Step.breath, 11.seconds);
        steps.after(Step.nova, 5.seconds);
        steps.after(Step.cleave, 8.seconds);
        steps.after(Step.tailSweep, 20.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!lowYelled && e.after < 15)
        {
            lowYelled = true;
            me.say(sayHalflife);
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (me.random(5) == 0)
            me.say(sayKillTarget, e.victim);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.intro:
            intro(me);
            break;
        case Step.speech:
            if (speechNum == 0)
            {
                me.say(sayLine2);
                steps.after(step, 16.seconds);
            }
            else if (speechNum == 1)
            {
                me.say(sayLine3);
                steps.after(step, 10.seconds);
            }
            else
            {
                me.setFaction(factionHostile);
                me.zoneCombat();
                if (const nearest = me.selectTarget(Pick.nearest))
                    me.attack(nearest);
            }
            ++speechNum;
            break;
        case Step.adrenalineTank:
            steps.after(step, me.castSpell(burningAdrenalineTank) == ActionResult.ok ? 45.seconds : retry);
            break;
        case Step.adrenaline:
            const target = me.selectTarget(Pick.random, PickFilter.player | PickFilter.manaUser);
            steps.after(step, target && me.castSpell(burningAdrenaline, target) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.breath:
            steps.after(step, me.castSpell(flameBreath) == ActionResult.ok ? between(me, 4000, 8000) : retry);
            break;
        case Step.nova:
            steps.after(step, me.castSelf(fireNova) == ActionResult.ok ? 5.seconds : retry);
            break;
        case Step.cleave:
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.tailSweep:
            steps.after(step, me.castSelf(tailSweep) == ActionResult.ok ? 20.seconds : retry);
            break;
        }
    }

    /// Nefarius at his throne, corrupting him.
    private void intro(ref CreatureContext me)
    {
        uint next;
        switch (introPhase)
        {
        case 0:
            nefarius = me.summon(npcVictorNefarius, nefariusAtThrone, 25_000);
            next = 1000;
            break;
        case 1:
            if (nefarius)
            {
                me.castAs(nefarius, nefariusCorruption, me.self, true);
                me.signal(nefarius, BwlSignal.nefariusLine, sayNefariusCorrupt1);
            }
            next = 14_000;
            break;
        case 2:
            if (nefarius)
                me.signal(nefarius, BwlSignal.nefariusLine, sayNefariusCorrupt2);
            next = 2000;
            break;
        case 3:
            if (nefarius)
                me.castAs(nefarius, redLightning, me.self);
            me.npcFlags(npcFlagGossip | npcFlagQuestGiver);
            me.removeAura(me.self, nefariusCorruption);
            break;
        default:
            break;
        }
        ++introPhase;
        if (next)
            steps.after(Step.intro, next.msecs);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        lowYelled = false;
        me.setHealthPercent(30);
        me.signalDungeon(BwlEncounter.vaelastrasz, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(BwlEncounter.vaelastrasz, EncounterState.done);
    }
}

/// Broodlord Lashlayer: Cleave, Knock Away, Blast Wave, Mortal Strike.
@creature("boss_broodlord")
struct Broodlord
{
    enum int sayAggro = -1_469_000;
    enum : uint { cleave = 15284, knockAway = 18670, blastWave = 23331, mortalStrike = 24573 }
    enum Step : ubyte { cleave, knockAway, blastWave, mortalStrike }
    Schedule!Step steps;

    mixin(encounterOf!"BwlEncounter.lashlayer");

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(BwlEncounter.lashlayer, EncounterState.inProgress);
        me.say(sayAggro);
        steps.after(Step.cleave, 8.seconds);
        steps.after(Step.knockAway, 12.seconds);
        steps.after(Step.blastWave, 20.seconds);
        steps.after(Step.mortalStrike, 30.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.cleave:
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? 7.seconds : retry);
            break;
        case Step.knockAway:
            steps.after(step, me.castSpell(knockAway) == ActionResult.ok ? between(me, 15_000, 30_000) : retry);
            break;
        case Step.blastWave:
            steps.after(step, me.castSelf(blastWave) == ActionResult.ok ? between(me, 8000, 16_000) : retry);
            break;
        case Step.mortalStrike:
            steps.after(step, me.castSpell(mortalStrike) == ActionResult.ok ? between(me, 25_000, 35_000) : retry);
            break;
        }
    }
}

/// What the three drakes share: Shadow Flame, Wing Buffet (halving the threat of those it hits), and
/// Thrash; each its own on top (`special`, every `first` then `low` .. `high` ms).
private mixin template Drake(BwlEncounter which, uint special, uint first, uint low, uint high, int emote = 0)
{
    enum : uint { shadowFlame = 22539, wingBuffet = 23339, thrash = 3391 }
    enum Step : ubyte { special, shadowFlame, wingBuffet, thrash }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(which, EncounterState.inProgress);
        steps.after(Step.special, first.msecs);
        steps.after(Step.shadowFlame, 18.seconds);
        steps.after(Step.wingBuffet, 30.seconds);
        steps.after(Step.thrash, 6.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.special:
            const ok = (special == 23340 ? me.castSpell(special) : me.castSelf(special)) == ActionResult.ok;
            if (ok && emote)
                me.say(emote);
            steps.after(step, ok ? between(me, low, high) : retry);
            break;
        case Step.shadowFlame:
            steps.after(step, me.castSelf(shadowFlame) == ActionResult.ok ? between(me, 15_000, 18_000) : retry);
            break;
        case Step.wingBuffet:
            if (me.castSelf(wingBuffet) == ActionResult.ok)
            {
                EntityRef[40] near;
                foreach (p; near[0 .. me.playersNear(20, near[])])
                    me.modifyThreat(p, -50);
                steps.after(step, between(me, 30_000, 35_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.thrash:
            steps.after(step, me.castSelf(thrash) == ActionResult.ok ? between(me, 2000, 6000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(which, EncounterState.done);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.signalDungeon(which, EncounterState.failed);
    }
}

/// Firemaw: Flame Buffet on top of the drakes' breath and buffets.
@creature("boss_firemaw")
struct Firemaw
{
    mixin Drake!(BwlEncounter.firemaw, 23341, 5000, 5000, 5000) drake;
    alias steps = drake.steps;
    alias on = drake.on;
}

/// Ebonroc: the Shadow of Ebonroc on his foe.
@creature("boss_ebonroc")
struct Ebonroc
{
    mixin Drake!(BwlEncounter.ebonroc, 23340, 45_000, 25_000, 35_000) drake;
    alias steps = drake.steps;
    alias on = drake.on;
}

/// Flamegor: frenzies.
@creature("boss_flamegor")
struct Flamegor
{
    mixin Drake!(BwlEncounter.flamegor, 23342, 10_000, 10_000, 15_000, -1_000_002) drake;
    alias steps = drake.steps;
    alias on = drake.on;
}

/// Chromaggus: the two breaths this copy drew, Brood Affliction, an elemental shield, frenzies, and an
/// enrage below a fifth of his health.
@creature("boss_chromaggus")
struct Chromaggus
{
    enum : int { emoteFrenzyKill = -1_000_001, emoteFrenzy = -1_000_002, emoteShimmer = -1_469_003 }
    enum : uint { broodAffliction = 23173, elementalShield = 22276, frenzy = 23128, enrage = 23537 }
    enum Step : ubyte { shield, breathLeft, breathRight, affliction, frenzy }
    Schedule!Step steps;
    bool enraged;

    mixin(encounterOf!"BwlEncounter.chromaggus");

    void reset(ref CreatureContext me)
    {
        enraged = false;
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(BwlEncounter.chromaggus, EncounterState.inProgress);
        steps.after(Step.shield, 0.msecs);
        steps.after(Step.breathLeft, 30.seconds);
        steps.after(Step.breathRight, 60.seconds);
        steps.after(Step.affliction, 7.seconds);
        steps.after(Step.frenzy, 15.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after < 20)
        {
            enraged = true;
            me.castSelf(enrage);
            me.say(emoteFrenzy);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shield:
            if (me.castSelf(elementalShield) == ActionResult.ok)
            {
                me.say(emoteShimmer);
                steps.after(step, 45.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.breathLeft, Step.breathRight:
            const breath = cast(uint) me.askDungeon(step == Step.breathLeft ? BwlQuestion.chromaLeftBreath
                : BwlQuestion.chromaRightBreath);
            steps.after(step, breath && me.castSelf(breath) == ActionResult.ok ? 60.seconds : retry);
            break;
        case Step.affliction:
            steps.after(step, me.castSelf(broodAffliction) == ActionResult.ok ? 7.seconds : retry);
            break;
        case Step.frenzy:
            if (me.castSelf(frenzy) == ActionResult.ok)
            {
                me.say(emoteFrenzyKill);
                steps.after(step, 15.seconds);
            }
            else
                steps.after(step, retry);
            break;
        }
    }
}

/**
 * Lord Victor Nefarius: spoken to, he begins the games: his drakonids pour from the tunnels while he
 * blinks about his hall casting; once forty-two of them are slain, Nefarian comes.
 */
@creature("boss_victor_nefarius")
struct VictorNefarius
{
    enum : int { sayGamesBegin1 = -1_469_004, sayGamesBegin2 = -1_469_005 }
    enum : uint
    {
        nefariusBarrier = 22663,
        shadowblink = 22664,
        shadowboltVolley = 22665,
        silence = 22666,
        shadowCommand = 22667,
        shadowbolt = 22677,
        fear = 22678,
    }
    enum : uint { textNefarius1 = 7134, textNefarius2 = 7198, textNefarius3 = 7199 }
    enum uint factionBlackDragon = 103, mapBlackwingLair = 469;

    enum Step : ubyte { dialogue, bolt, fear, volley, silence, command, blink }
    Schedule!Step steps;
    ubyte dialogueStep;
    bool corrupter; /// the one Vaelastrasz summoned for his intro

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.npcFlags(1);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == BwlSignal.nefariusLine)
        {
            corrupter = true;
            me.unitFlags(UnitFlag.notSelectable, true);
            me.say(e.value);
        }
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        if (corrupter)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "I've made no mistakes.", 1);
        me.sendGossip(e.player, textNefarius1, menu, false);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.consume();
        GossipMenu menu;
        switch (e.action)
        {
        case 1:
            me.emote(1);
            menu.add(GossipIcon.chat, "You have lost your mind, Nefarius. You speak in riddles.", 2);
            me.sendGossip(e.player, textNefarius2, menu, false);
            break;
        case 2:
            me.emote(1);
            menu.add(GossipIcon.chat, "Please do.", 3);
            me.sendGossip(e.player, textNefarius3, menu, false);
            break;
        case 3:
            me.npcFlags(0);
            me.closeGossip(e.player);
            dialogueStep = 0;
            steps.after(Step.dialogue, 0.msecs);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(BwlEncounter.nefarian, EncounterState.inProgress);
        steps.after(Step.bolt, 3.seconds);
        steps.after(Step.fear, 8.seconds);
        steps.after(Step.volley, 13.seconds);
        steps.after(Step.silence, 23.seconds);
        steps.after(Step.command, 30.seconds);
        steps.after(Step.blink, 40.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.dialogue:
            if (dialogueStep == 0)
            {
                me.say(sayGamesBegin1);
                steps.after(step, 4.seconds);
            }
            else if (dialogueStep == 1)
            {
                me.say(sayGamesBegin2);
                steps.after(step, 5.seconds);
            }
            else
            {
                // The games begin.
                me.standState(StandState.stand);
                me.setFaction(factionBlackDragon);
                me.castSelf(nefariusBarrier, true);
                me.castSelf(shadowblink);
                me.unitFlags(UnitFlag.immuneToPlayer, false);
                me.unitFlags(UnitFlag.notSelectable, true);
                me.combatMovement(false);
                me.zoneCombat();
            }
            ++dialogueStep;
            break;
        case Step.bolt, Step.silence:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            const bolt = step == Step.bolt;
            const ok = target && me.castSpell(bolt ? shadowbolt : silence, target) == ActionResult.ok;
            steps.after(step, !ok ? retry : bolt ? between(me, 2000, 4000) : between(me, 14_000, 23_000));
            break;
        case Step.fear, Step.command:
            const target = me.selectTarget(Pick.random, PickFilter.player, 1);
            const isFear = step == Step.fear;
            const ok = target && me.castSpell(isFear ? fear : shadowCommand, target) == ActionResult.ok;
            steps.after(step, !ok ? retry : isFear ? between(me, 10_000, 20_000) : between(me, 24_000, 30_000));
            break;
        case Step.volley:
            steps.after(step, me.castSelf(shadowboltVolley) == ActionResult.ok ? between(me, 19_000, 28_000) : retry);
            break;
        case Step.blink:
            steps.after(step, me.castSelf(shadowblink) == ActionResult.ok ? between(me, 30_000, 40_000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (corrupter)
            return;
        me.npcFlags(1);
        me.setFaction(0);
        me.unitFlags(UnitFlag.notSelectable, false);
        me.combatMovement(true);
        me.signalDungeon(BwlEncounter.nefarian, EncounterState.failed);
    }
}

/**
 * Nefarian: flies down from his perch and lands to fight: Shadow Flame, Bellowing Roar, Veil of Shadow,
 * Cleave, Tail Lash, and his class calls; below a fifth of his health the drakonids' bones rise.
 */
@creature("boss_nefarian")
struct Nefarian
{
    enum : int
    {
        sayAggro = -1_469_007,
        sayXHealth = -1_469_008,
        sayShadowFlame = -1_469_009,
        sayRaiseSkeletons = -1_469_010,
        saySlay = -1_469_011,
        sayDeath = -1_469_012,
    }
    enum : uint
    {
        shadowFlamePassive = 22992,
        shadowFlame = 22539,
        bellowingRoar = 22686,
        veilOfShadow = 22687,
        cleave = 19983,
        tailLash = 23364,
        raiseDrakonid = 23362,
        doubleAttack = 19818,
        speedBurst = 25184,
    }
    /// Class calls by class (`Classes`): the spell and the line.
    static immutable uint[12] classSpells = [0, 23397, 23418, 23436, 23414, 23401, 0, 23425, 23410, 23427, 0, 23398];
    static immutable int[12] classLines = [0, -1_469_014, -1_469_017, -1_469_020, -1_469_021, -1_469_016, 0,
        -1_469_018, -1_469_013, -1_469_019, 0, -1_469_015];
    /// His way down (`creature_movement_template` of his).
    static immutable Location[9] landing = [
        Location(-7348.85f, -1495.13f, 552.515f), Location(-7348.54f, -1494.18f, 552.515f),
        Location(-7392.87f, -1475.7f, 544.619f), Location(-7423.42f, -1437.66f, 535.314f),
        Location(-7445.25f, -1402.11f, 523.842f), Location(-7460.38f, -1372.6f, 513.092f),
        Location(-7479.81f, -1331.76f, 498.759f), Location(-7492.58f, -1295.35f, 488.091f),
        Location(-7502f, -1256.5f, 476.758f),
    ];

    enum Step : ubyte { initialYell, attackStart, shadowFlame, roar, veil, cleave, tailLash, classCall }
    Schedule!Step steps;
    bool raised, lowYelled, landed;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        foreach (spell; [speedBurst, doubleAttack, shadowFlamePassive])
            if (!me.hasAura(me.self, spell))
                me.castSelf(spell, true);
        steps.after(Step.initialYell, 10.seconds);
        me.reactState(Reaction.passive);
        me.melee(false);
        me.combatMovement(false);
        me.flying(true);
        me.moveTo(landing[1], 1, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (landed || e.point < 1 || e.point >= landing.length)
            return;
        if (e.point == 1)
            me.say(sayAggro);
        if (e.point + 1 < landing.length)
            return me.moveTo(landing[e.point + 1], e.point + 1, true);
        // Down.
        landed = true;
        me.emote(293); // EMOTE_ONESHOT_LAND
        me.flying(false);
        steps.after(Step.attackStart, 4.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (me.random(5) == 0)
            me.say(saySlay, e.victim);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!raised && e.after < 20 && me.castSelf(raiseDrakonid) == ActionResult.ok)
        {
            raised = true;
            me.say(sayRaiseSkeletons);
        }
        if (!lowYelled && e.after < 5)
        {
            lowYelled = true;
            me.say(sayXHealth);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.initialYell:
            me.say(sayShadowFlame);
            break;
        case Step.attackStart:
            me.melee(true);
            me.reactState(Reaction.aggressive);
            me.removeAura(me.self, speedBurst);
            me.combatMovement(true);
            me.unitFlags(UnitFlag.notSelectable, false);
            me.zoneCombat();
            if (const target = me.selectTarget(Pick.random))
                me.attack(target);
            steps.after(Step.shadowFlame, 12.seconds);
            steps.after(Step.roar, 30.seconds);
            steps.after(Step.veil, 15.seconds);
            steps.after(Step.cleave, 7.seconds);
            steps.after(Step.tailLash, 10.seconds);
            steps.after(Step.classCall, 35.seconds);
            break;
        case Step.shadowFlame:
            steps.after(step, me.castSelf(shadowFlame) == ActionResult.ok ? 12.seconds : retry);
            break;
        case Step.roar:
            steps.after(step, me.castSelf(bellowingRoar) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.veil:
            steps.after(step, me.castSpell(veilOfShadow) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.cleave:
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? 7.seconds : retry);
            break;
        case Step.tailLash:
            steps.after(step, me.castSelf(tailLash) == ActionResult.ok ? 10.seconds : retry);
            break;
        case Step.classCall:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            const cls = target ? me.classOf(target) : 0;
            if (cls < classSpells.length && classSpells[cls] && me.castSelf(classSpells[cls]) == ActionResult.ok)
            {
                me.say(classLines[cls]);
                steps.after(step, between(me, 35_000, 40_000));
            }
            else
                steps.after(step, retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
        me.signalDungeon(BwlEncounter.nefarian, EncounterState.failed);
        me.despawn();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
        me.signalDungeon(BwlEncounter.nefarian, EncounterState.done);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptKind, ScriptRuntime;

    class FakeLair : BlackHole!InstanceHost
    {
        Signal[] signals;
        bool[ulong] opened;
        EntityRef[] summoned, despawned, objectsGone;
        int[] said;
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override bool hostAlive(EntityRef) { return true; }
        override ActionResult hostDoor(EntityRef door, bool open)
        {
            opened[door.guid] = open;
            return ActionResult.ok;
        }
        override EntityRef hostSummon(uint entry, Location, uint)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(entry) << 24) | summoned.length);
            return summoned[$ - 1];
        }
        override ActionResult hostDespawnCreature(EntityRef c, uint) { despawned ~= c; return ActionResult.ok; }
        override ActionResult hostDespawnObject(EntityRef o) { objectsGone ~= o; return ActionResult.ok; }
        override ActionResult hostSay(EntityRef, int text, EntityRef) { said ~= text; return ActionResult.ok; }
    }

    EntityRef bwlObject(uint entry, uint spawn) { return EntityRef(0xF110_0000_0000_0000UL | (ulong(entry) << 24) | spawn); }
    EntityRef bwlCreature(uint entry, uint spawn) { return EntityRef(0xF130_0000_0000_0000UL | (ulong(entry) << 24) | spawn); }
}

/// Blackwing Lair's copy: Grethok's fight starts Razorgore's room (the main gate shuts, defenders come
/// from the generators); every egg broken frees Razorgore; his death opens the way on. Nefarius' games:
/// forty-two drakonids slain bring Nefarian.
unittest
{
    alias self = dmangos.scripts.blackwinglair;
    auto runtime = ScriptRuntime.of!self();
    auto lair = new FakeLair;
    auto c = InstanceContext(lair);
    auto h = runtime.create(ScriptKind.instance, "instance_blackwing_lair");
    const gate = bwlObject(goDoorRazorgoreEnter, 1), exit = bwlObject(goDoorRazorgoreExit, 2);
    const razorgore = bwlCreature(npcRazorgore, 3), nefarius = bwlCreature(npcVictorNefarius, 4);
    runtime.raise(h, c, ObjectLoaded(gate));
    runtime.raise(h, c, ObjectLoaded(exit));
    runtime.raise(h, c, CreatureLoaded(razorgore));
    runtime.raise(h, c, CreatureLoaded(nefarius));
    foreach (i; 0 .. 4)
        runtime.raise(h, c, CreatureLoaded(bwlCreature(npcMonsterGenerator, 10 + i)));
    foreach (i; 0 .. 3)
        runtime.raise(h, c, ObjectLoaded(bwlObject(goBlackDragonEgg, 20 + i)));
    assert(lair.opened[gate.guid] && !lair.opened[exit.guid]);

    // Grethok attacked: the gate shuts; forty seconds on, the defenders come.
    runtime.raise(h, c, CreatureEngaged(bwlCreature(npcGrethok, 5), EntityRef(7)));
    assert(!lair.opened[gate.guid]);
    runtime.tick(h, c, 40_000);
    assert(lair.summoned.length == 4, "four defenders");

    // Every egg broken: Razorgore is free; the defenders go.
    foreach (i; 0 .. 3)
        runtime.raise(h, c, ObjectUsedHere(bwlObject(goBlackDragonEgg, 20 + i), EntityRef(7)));
    runtime.tick(h, c, 100);
    assert(lair.objectsGone.length == 3);
    assert(lair.signals[$ - 1] == Signal(razorgore, BwlSignal.eggsBroken, 0));
    assert(lair.despawned.length == 4);
    runtime.raise(h, c, CreatureDied(razorgore, EntityRef(7)));
    assert(lair.opened[exit.guid] && lair.opened[gate.guid]);

    // Nefarius' games: the tunnels' spawners, then Nefarian.
    runtime.raise(h, c, Signal(nefarius, BwlEncounter.nefarian, EncounterState.inProgress));
    const before = lair.summoned.length;
    assert(before == 6, "the two tunnels' spawners");
    foreach (i; 0 .. 42)
        runtime.raise(h, c, CreatureDied(bwlCreature(14261, 100 + i), EntityRef(7)));
    runtime.tick(h, c, 5000);
    assert(lair.summoned[$ - 1].entry == npcNefarian);
}

version (unittest)
{
    class FakeDrake : BlackHole!CreatureHost
    {
        uint[] casts;
        Signal[] dungeon;
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override void hostSignalDungeon(uint id, int value) { dungeon ~= Signal(EntityRef.init, id, value); }
    }
}

/// The drakes share their breath and buffets, each with its own on top, and tell the copy how it goes.
unittest
{
    import std.algorithm.searching : canFind;

    alias self = dmangos.scripts.blackwinglair;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeDrake;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_ebonroc");
    assert(runtime.handles!Died(h) && runtime.handles!Reset(h) && runtime.handles!EnteredCombat(h));
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    foreach (_; 0 .. 460)
        runtime.tick(h, me, 100);
    assert(host.casts.canFind(23340) && host.casts.canFind(Ebonroc.drake.shadowFlame));
    runtime.raise(h, me, Died(EntityRef(7)));
    assert(host.dungeon[$ - 1] == Signal(EntityRef.init, BwlEncounter.ebonroc, EncounterState.done));
}
