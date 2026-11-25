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
import dmangos.script.state : appended, AppendedSince;

/// Where `who` is, as `ctx` sees it (`Location.init` if it is not here).
private Location where(C)(ref C ctx, EntityRef who)
{
    Location at;
    ctx.locationOf(who, at);
    return at;
}

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
    npcFiremaw = 11983,
    npcEbonroc = 14601,
    npcFlamegor = 11981,
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
    goBlackDragonEgg = 177807, goOrbOfDomination = 177808,
    goSuppressionDevice = 179784,
    npcOrbTrigger = 14449,
}

/// Native fights that save each completed ability with the boss's combat state, indexed by encounter.
private immutable uint[BwlEncounter.max + 1] checkpointedBossEntries = [
    0, 0, 0, npcFiremaw, npcEbonroc, npcFlamegor, npcChromaggus, 0,
];

private enum uint shadowOfEbonroc = 23340, flameBuffet = 23341, flamegorFrenzy = 23342, ebonrocShadowHeal = 23394;

bool isBlackwingRecoveryAura(uint spell)
{
    return spell == shadowOfEbonroc || spell == flameBuffet || Chromaggus.isRecoveryAura(spell);
}

/// The weekly selection's events (`event_weekly_chromatic_selection`): Chromaggus' left breath (five), his right
/// (five), then the left tunnel's drakonids (five) and the right's, in the order of `leftBreaths` and `spawners`.
private enum uint leftBreathEvents = 8446, rightBreathEvents = 8451, leftTunnelEvents = 8520, rightTunnelEvents = 8525;
/// The Orb of Domination's possession (`event_razorgore_possess`).
private enum uint possessEvent = 8302;

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
    saveNefarian = 104, /// Nefarian's flight or combat changed
    saveVael = 105,     /// Vaelastrasz's scene or speech moved to its next step
    suppressionDisarmed = 106, /// save the device until it rearms
    suppressionFinished = 107, /// the device rearmed or shut down
    suppressionShutdown = 108, /// Lashlayer died
    saveBossCombat = 109, /// a combat step advanced
}

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

private void nextCombatStep(E)(ref CreatureContext me, ref Schedule!E steps, E step, bool casted, lazy Duration delay)
{
    steps.after(step, casted ? delay : retry);
    if (casted)
        me.signalDungeon(BwlSignal.saveBossCombat);
}

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
    enum uint possessVisual = 23014;

    EncounterState[BwlEncounter.max + 1] encounters;
    uint leftBreath, rightBreath, leftTunnel, rightTunnel;
    ushort eggsBroken;

    @transient EntityRef razorgore, vaelastrasz, nefarius, troops;
    @transient EntityRef[checkpointedBossEntries.length] checkpointedBosses;
    @transient EntityRef vaelCorruptor;
    @transient EntityRef[6] doors; /// enter, exit, Nefarian, Chromaggus' exit, Vaelastrasz', Lashlayer's
    @transient EntityRef[8] generators;
    @transient ubyte generatorCount;
    @transient EntityRef[] loadedEggs;
    @transient EntityRef[64] defenders;
    @transient ubyte dragonspawn, blackwingDefenders;
    @transient EntityRef[] drakonidsSeen;
    @transient EntityRef[] eggsToGo;
    @transient bool recoveringRazorgore, resetOldEggPhase, recoveringNefarian, recoveringVael;
    @transient bool[checkpointedBossEntries.length] recoveringBosses;

    enum Step : ubyte { defense, nefarian, eggsGone }
    Schedule!Step steps;
    @appended EntityRef[] brokenEggs;
    @appended ushort eggTotal;
    @AppendedSince(2) EntityRef[2] tunnelSpawners;
    @AppendedSince(2) EntityRef nefarianDragon;
    @AppendedSince(2) ubyte drakonidsSlain;

    void on(ref InstanceContext copy, const ref Restored e)
    {
        if (copy.hasSavedGameObject(goSuppressionDevice))
            copy.waitForPlayer();
        if (copy.entryKilled(npcLashlayer))
            set(copy, BwlEncounter.lashlayer, EncounterState.done);
        foreach (i, entry; checkpointedBossEntries)
            if (entry && encounters[i] == EncounterState.inProgress)
            {
                if (copy.entryKilled(entry))
                    set(copy, cast(BwlEncounter) i, EncounterState.done);
                else if (copy.hasSavedCreature(entry))
                {
                    recoveringBosses[i] = true;
                    copy.waitForPlayer();
                }
            }
        restoreNefarian(copy);
        const vael = encounters[BwlEncounter.vaelastrasz];
        if (vael == EncounterState.special || vael == EncounterState.inProgress)
        {
            if (copy.entryKilled(npcVaelastrasz))
                set(copy, BwlEncounter.vaelastrasz, EncounterState.done);
            else if (copy.hasSavedCreature(npcVaelastrasz))
            {
                recoveringVael = vael == EncounterState.inProgress;
                copy.waitForPlayer();
            }
            else if (vael == EncounterState.special)
                set(copy, BwlEncounter.vaelastrasz, EncounterState.notStarted); // older saves lacked the scene
        }
        const state = encounters[BwlEncounter.razorgore];
        if (state == EncounterState.special && copy.entryKilled(npcRazorgore))
        {
            set(copy, BwlEncounter.razorgore, EncounterState.done);
            return;
        }
        if (state == EncounterState.inProgress && (eggsBroken != brokenEggs.length || (eggsBroken && !eggTotal)))
        {
            // Older saves kept a count but could not identify the eggs that count referred to.
            encounters[BwlEncounter.razorgore] = EncounterState.failed;
            steps.cancel(Step.defense);
            steps.cancel(Step.eggsGone);
            eggsBroken = 0;
            brokenEggs = null;
            resetOldEggPhase = true;
            copy.waitForPlayer();
        }
        else if (state == EncounterState.inProgress || (state == EncounterState.special && copy.hasSavedCreature(npcRazorgore)))
        {
            recoveringRazorgore = true;
            copy.waitForPlayer();
        }
    }

    void on(ref InstanceContext copy, const ref PlayerEntered e)
    {
        foreach (i, ref recovering; recoveringBosses)
            if (recovering)
            {
                recovering = false;
                const boss = checkpointedBosses[i];
                if (boss && !copy.alive(copy.victimOf(boss)))
                    copy.attack(boss, e.player);
            }
        if (recoveringVael)
        {
            recoveringVael = false;
            if (vaelastrasz && !copy.alive(copy.victimOf(vaelastrasz)))
                copy.attack(vaelastrasz, e.player);
        }
        if (recoveringNefarian)
        {
            recoveringNefarian = false;
            if (encounters[BwlEncounter.nefarian] == EncounterState.inProgress)
            {
                if (nefarius && !copy.alive(copy.victimOf(nefarius)))
                    copy.attack(nefarius, e.player);
                foreach (drakonid; drakonidsSeen)
                    if (!copy.alive(copy.victimOf(drakonid)))
                        copy.attack(drakonid, e.player);
            }
        }
        if (resetOldEggPhase)
        {
            resetOldEggPhase = false;
            copy.respawnKilled(npcGrethok);
            copy.checkpoint();
        }
        if (!recoveringRazorgore)
            return;
        recoveringRazorgore = false;
        if (encounters[BwlEncounter.razorgore] == EncounterState.special)
            return; // the boss's native combat state resumes when the raid returns
        foreach (defender; defenders)
            if (defender)
            {
                const target = copy.victimOf(defender);
                if (!copy.alive(target) || target == razorgore)
                    copy.attack(defender, e.player);
            }
        if (eggsBroken && eggsBroken == eggTotal)
            steps.after(Step.eggsGone, 0.msecs);
    }

    private void restoreNefarian(ref InstanceContext copy)
    {
        const state = encounters[BwlEncounter.nefarian];
        if (state != EncounterState.inProgress && state != EncounterState.special)
            return;
        const hasWave = tunnelSpawners[0] && tunnelSpawners[1]
            && copy.hasSavedCreature(tunnelSpawners[0]) && copy.hasSavedCreature(tunnelSpawners[1]);
        const hasDragon = nefarianDragon && copy.hasSavedCreature(nefarianDragon);
        if (state == EncounterState.inProgress ? hasWave : hasDragon || steps.pending(Step.nefarian))
        {
            recoveringNefarian = true;
            copy.waitForPlayer();
        }
        else
        {
            // Older active saves omitted the actors needed to resume this stage.
            encounters[BwlEncounter.nefarian] = EncounterState.failed;
            cleanupNefarian(copy);
            copy.checkpoint();
        }
    }

    void on(ref InstanceContext copy, const ref EventHappened e)
    {
        if (e.event == possessEvent)
        {
            // A player took Razorgore through the orb: the orb's trigger shows it (not the database script).
            copy.consume();
            Location at;
            EntityRef[1] trigger;
            if (copy.locationOf(e.source, at) && copy.creaturesNear(at, npcOrbTrigger, 30, trigger[]))
                copy.castSpell(trigger[0], possessVisual, trigger[0]);
            return;
        }
        // The week's selection: what it picks wins over the copy's own draw while the fight is not begun.
        draw(copy);
        const chroma = encounters[BwlEncounter.chromaggus] == EncounterState.notStarted;
        const nef = encounters[BwlEncounter.nefarian] == EncounterState.notStarted;
        if (e.event >= leftBreathEvents && e.event < leftBreathEvents + 5 && chroma)
            leftBreath = leftBreaths[e.event - leftBreathEvents];
        else if (e.event >= rightBreathEvents && e.event < rightBreathEvents + 5 && chroma)
            rightBreath = rightBreaths[e.event - rightBreathEvents];
        else if (e.event >= leftTunnelEvents && e.event < leftTunnelEvents + 5 && nef)
            leftTunnel = spawners[e.event - leftTunnelEvents];
        else if (e.event >= rightTunnelEvents && e.event < rightTunnelEvents + 5 && nef)
            rightTunnel = spawners[e.event - rightTunnelEvents];
    }

    private static immutable uint[6] doorEntries = [goDoorRazorgoreEnter, goDoorRazorgoreExit, goDoorNefarian,
        goDoorChromaggusExit, goDoorVaelastrasz, goDoorLashlayer];

    /// `who` among `those` (once), if there is room.
    private static bool remember(EntityRef[] those, EntityRef who)
    {
        foreach (ref t; those)
            if (t == who)
                return false;
        foreach (ref t; those)
            if (!t)
            {
                t = who;
                return true;
            }
        return false;
    }

    /// Whether door `i` stands open now.
    private bool doorOpen(size_t i) const
    {
        final switch (i)
        {
        case 0: // the main gate: shut while any encounter before Nefarian is under way
            foreach (encounter, e; encounters[0 .. BwlEncounter.nefarian])
                if (e == EncounterState.inProgress
                    || (e == EncounterState.special && encounter != BwlEncounter.vaelastrasz))
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
        import std.algorithm.searching : canFind, countUntil;

        draw(copy);
        switch (e.creature.entry)
        {
        case npcRazorgore:
            razorgore = e.creature;
            break;
        case npcVaelastrasz:
            vaelastrasz = e.creature;
            break;
        case npcFiremaw, npcEbonroc, npcFlamegor, npcChromaggus:
            if (!e.summoned)
                checkpointedBosses[checkpointedBossEntries[].countUntil(e.creature.entry)] = e.creature;
            break;
        case npcVictorNefarius:
            // Vaelastrasz's intro can load a second copy of Victor Nefarius.
            if (!e.summoned)
            {
                nefarius = e.creature;
                if (nefarianDragon || encounters[BwlEncounter.nefarian] == EncounterState.done)
                    copy.despawn(nefarius);
            }
            else if (encounters[BwlEncounter.vaelastrasz] == EncounterState.special)
                vaelCorruptor = e.creature;
            break;
        case npcNefariansTroops:
            troops = e.creature;
            break;
        case npcMonsterGenerator:
            if (remember(generators[], e.creature))
                ++generatorCount;
            break;
        case npcLegionnaire, npcMage, npcDragonspawn:
            if (encounters[BwlEncounter.razorgore] == EncounterState.inProgress)
                registerDefender(e.creature);
            else if (recoveringRazorgore && encounters[BwlEncounter.razorgore] == EncounterState.special)
                copy.despawn(e.creature);
            break;
        default:
            const state = encounters[BwlEncounter.nefarian];
            if (state == EncounterState.special && spawners[].canFind(e.creature.entry))
                copy.despawn(e.creature);
            if ((state == EncounterState.inProgress || state == EncounterState.special)
                && drakonids[].canFind(e.creature.entry) && !drakonidsSeen.canFind(e.creature))
            {
                drakonidsSeen ~= e.creature;
                copy.checkpointCreature(e.creature);
            }
            break;
        }
    }

    private void registerDefender(EntityRef defender)
    {
        if (!remember(defenders[], defender))
            return;
        if (defender.entry == npcDragonspawn)
            ++dragonspawn;
        else
            ++blackwingDefenders;
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
        {
            import std.algorithm.comparison : max;
            import std.algorithm.searching : canFind;

            if (!loadedEggs.canFind(e.object))
                loadedEggs ~= e.object;
            eggTotal = max(eggTotal, cast(ushort) loadedEggs.length);
            const state = encounters[BwlEncounter.razorgore];
            if (state == EncounterState.special || state == EncounterState.done || brokenEggs.canFind(e.object))
                copy.despawnObject(e.object);
        }
        if (e.object.entry == goSuppressionDevice && encounters[BwlEncounter.lashlayer] == EncounterState.done)
            copy.signal(e.object, BwlSignal.suppressionShutdown);
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
        const state = encounters[BwlEncounter.razorgore];
        if (e.creature.entry == npcGrethok && (state == EncounterState.notStarted || state == EncounterState.failed))
        {
            set(copy, BwlEncounter.razorgore, EncounterState.inProgress);
            copy.spawnObjects(goBlackDragonEgg, 0);
            steps.after(Step.defense, 40.seconds);
            copy.checkpointCreature(e.creature);
        }
        else if (e.creature.entry == npcRazorgore && state == EncounterState.special)
            copy.checkpointCreature(e.creature);
    }

    void on(ref InstanceContext copy, const ref ObjectUsedHere e)
    {
        import std.algorithm.searching : canFind;
        if (e.object.entry == goBlackDragonEgg)
            copy.consume();
        if (encounters[BwlEncounter.razorgore] != EncounterState.inProgress)
            return;
        if (e.object.entry == goOrbOfDomination && e.player.isPlayer && razorgore)
        {
            if (!copy.hasAura(e.player, 23958) && !copy.hasAura(razorgore, 19832))
            {
                copy.castSpell(e.player, 19832, razorgore);
                if (copy.hasAura(razorgore, 19832))
                    copy.castSpell(e.player, 23958, e.player);
            }
            return;
        }
        if (e.object.entry != goBlackDragonEgg || !razorgore || e.player != razorgore || brokenEggs.canFind(e.object))
            return;
        brokenEggs ~= e.object;
        ++eggsBroken;
        if (razorgore && copy.random(2))
            copy.say(razorgore, sayEggsBroken1 - copy.random(3));
        eggsToGo ~= e.object;
        steps.after(Step.eggsGone, 0.msecs); // once the use is over
        copy.checkpoint();
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
        {
            copy.removeAura(razorgore, 19832);
            copy.signal(razorgore, BwlSignal.eggsBroken);
        }
        foreach (ref d; defenders)
            if (d)
            {
                copy.despawn(d, 10_000);
                d = EntityRef.init;
            }
        dragonspawn = blackwingDefenders = 0;
        if (razorgore)
            copy.checkpointCreature(razorgore);
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        import std.algorithm.searching : countUntil;

        switch (e.creature.entry)
        {
        case npcRazorgore:
            if (encounters[BwlEncounter.razorgore] == EncounterState.special)
            {
                set(copy, BwlEncounter.razorgore, EncounterState.done);
                copy.checkpoint();
            }
            break;
        case npcGrethok:
            if (encounters[BwlEncounter.razorgore] == EncounterState.inProgress)
                copy.checkpoint();
            break;
        case npcLashlayer:
            // The native spawn's death is recorded before this event.
            if (!e.summoned)
                set(copy, BwlEncounter.lashlayer, EncounterState.done);
            break;
        case npcFiremaw, npcEbonroc, npcFlamegor, npcChromaggus:
            if (!e.summoned)
            {
                const i = checkpointedBossEntries[].countUntil(e.creature.entry);
                checkpointedBosses[i] = e.creature;
                set(copy, cast(BwlEncounter) i, EncounterState.done);
            }
            break;
        case npcLegionnaire, npcMage, npcDragonspawn:
            foreach (ref defender; defenders)
                if (defender == e.creature)
                {
                    defender = EntityRef.init;
                    if (e.creature.entry == npcDragonspawn)
                        --dragonspawn;
                    else
                        --blackwingDefenders;
                    copy.checkpoint();
                    break;
                }
            break;
        default:
            const index = drakonidsSeen.countUntil(e.creature);
            if (index >= 0)
            {
                drakonidsSeen = drakonidsSeen[0 .. index] ~ drakonidsSeen[index + 1 .. $];
                if (encounters[BwlEncounter.nefarian] == EncounterState.inProgress && ++drakonidsSlain == drakonidsToSlay)
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
                copy.checkpoint();
            }
            break;
        }
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        import std.algorithm.searching : countUntil;

        if (e.id == BwlSignal.suppressionDisarmed || e.id == BwlSignal.suppressionFinished)
        {
            if (e.from.isGameObject && e.from.entry == goSuppressionDevice)
            {
                if (e.id == BwlSignal.suppressionDisarmed)
                    copy.checkpointObject(e.from);
                else
                    copy.releaseCheckpointActor(e.from);
            }
            return;
        }
        if (e.id == BwlSignal.vaelTrigger)
        {
            if (encounters[BwlEncounter.vaelastrasz] == EncounterState.notStarted && vaelastrasz)
            {
                encounters[BwlEncounter.vaelastrasz] = EncounterState.special;
                copy.signal(vaelastrasz, BwlSignal.vaelIntro);
                checkpointVael(copy);
            }
            return;
        }
        if (e.id == BwlSignal.saveVael)
        {
            if (e.from == vaelastrasz && encounters[BwlEncounter.vaelastrasz] == EncounterState.special)
                checkpointVael(copy);
            return;
        }
        if (e.id == BwlSignal.saveNefarian)
        {
            if (e.from == nefarianDragon && encounters[BwlEncounter.nefarian] == EncounterState.special)
                copy.checkpointCreature(nefarianDragon);
            return;
        }
        if (e.id == BwlSignal.saveBossCombat)
        {
            const i = checkpointedBossEntries[].countUntil(e.from.entry);
            if (e.from.isCreature && i >= 0 && (!checkpointedBosses[i] || e.from == checkpointedBosses[i])
                && encounters[i] == EncounterState.inProgress)
            {
                checkpointedBosses[i] = e.from; // a clean handoff can bring a boss in without CreatureLoaded
                copy.checkpointCreature(e.from);
            }
            return;
        }
        if (e.id > BwlEncounter.max)
            return;
        if (e.id == BwlEncounter.nefarian && e.value == EncounterState.inProgress && e.from.entry == npcVictorNefarius)
            nefarius = e.from;
        if (e.from.isCreature && e.from.entry == checkpointedBossEntries[e.id])
            checkpointedBosses[e.id] = e.from;
        set(copy, cast(BwlEncounter) e.id, cast(EncounterState) e.value);
    }

    /// An encounter's new state, and what follows from it.
    private void set(ref InstanceContext copy, BwlEncounter which, EncounterState state)
    {
        const was = encounters[which];
        if ((which == BwlEncounter.lashlayer || checkpointedBossEntries[which]) && was == EncounterState.done)
            return;
        encounters[which] = state;
        final switch (which)
        {
        case BwlEncounter.razorgore:
            if (state == EncounterState.failed)
            {
                steps.cancel(Step.defense);
                steps.cancel(Step.eggsGone);
                eggsToGo = brokenEggs = null;
                eggsBroken = 0;
                foreach (ref d; defenders)
                    if (d)
                    {
                        copy.despawn(d);
                        d = EntityRef.init;
                    }
                dragonspawn = blackwingDefenders = 0;
                copy.spawnObjects(goBlackDragonEgg, 0);
                copy.respawnKilled(npcGrethok);
                if (razorgore)
                    copy.say(razorgore, sayRazorgoreDeath);
                copy.checkpoint();
            }
            break;
        case BwlEncounter.nefarian:
            if (state == EncounterState.inProgress && was != EncounterState.inProgress && nefarius)
            {
                drakonidsSlain = 0;
                tunnelSpawners[0] = copy.summon(leftTunnel, nefarianLocs[0], 3600 * 1000);
                tunnelSpawners[1] = copy.summon(rightTunnel, nefarianLocs[1], 3600 * 1000);
                copy.checkpointCreature(nefarius);
                foreach (spawner; tunnelSpawners)
                    if (spawner)
                        copy.checkpointCreature(spawner);
            }
            if (state == EncounterState.failed)
                cleanupNefarian(copy);
            if (state == EncounterState.done)
                nefarianDragon = EntityRef.init;
            copy.checkpoint();
            break;
        case BwlEncounter.vaelastrasz:
            checkpointVael(copy);
            break;
        case BwlEncounter.lashlayer:
            if (state == EncounterState.done)
            {
                copy.signalObjects(goSuppressionDevice, BwlSignal.suppressionShutdown);
                copy.checkpoint();
            }
            break;
        case BwlEncounter.firemaw, BwlEncounter.ebonroc, BwlEncounter.flamegor, BwlEncounter.chromaggus:
            if (state == EncounterState.inProgress && checkpointedBosses[which])
                copy.checkpointCreature(checkpointedBosses[which]);
            else if (was == EncounterState.inProgress || state == EncounterState.done)
                copy.releaseCheckpointActor(checkpointedBosses[which]);
            break;
        }
        updateDoors(copy);
    }

    private void checkpointVael(ref InstanceContext copy)
    {
        const state = encounters[BwlEncounter.vaelastrasz];
        if ((state == EncounterState.special || state == EncounterState.inProgress) && vaelastrasz)
        {
            copy.checkpointCreature(vaelastrasz);
            if (state == EncounterState.special && vaelCorruptor)
                copy.checkpointCreature(vaelCorruptor);
        }
        else
            copy.checkpoint();
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
        foreach (d; drakonidsSeen)
            if (copy.alive(d))
                copy.despawn(d);
        drakonidsSeen = null;
        drakonidsSlain = 0;
        nefarianDragon = EntityRef.init;
    }

    void on(ref InstanceContext copy, Step step)
    {
        final switch (step)
        {
        case Step.defense:
            defend(copy);
            steps.after(Step.defense, 15.seconds);
            copy.checkpoint();
            break;
        case Step.nefarian:
            // Nefarian comes; Nefarius blinks away.
            nefarianDragon = copy.summon(npcNefarian, nefarianLocs[2], 0);
            if (!nefarianDragon)
            {
                steps.after(Step.nefarian, retry);
                copy.checkpoint();
                break;
            }
            if (nefarius && copy.alive(nefarius))
            {
                copy.castSpell(nefarius, 22_681, nefarius); // Shadowblink
                copy.despawn(nefarius, 2500);
            }
            copy.checkpointCreature(nefarianDragon);
            copy.log("Nefarian comes");
            break;
        case Step.eggsGone:
            foreach (g; eggsToGo)
                copy.despawnObject(g);
            eggsToGo = null;
            if (eggsBroken >= eggTotal && eggTotal && encounters[BwlEncounter.razorgore] == EncounterState.inProgress)
                allEggsBroken(copy);
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
            const made = copy.summon(entry, where(copy, generator), 0);
            if (!made)
                continue;
            registerDefender(made);
            copy.checkpointCreature(made);
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
        if (me.creaturesNearby(npcGrethok, 10, grethok[]))
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
            me.signalDungeon(BwlSignal.saveVael);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(essenceOfTheRed);
        steps.after(Step.adrenalineTank, 45.seconds);
        steps.after(Step.adrenaline, 15.seconds);
        steps.after(Step.breath, 11.seconds);
        steps.after(Step.nova, 5.seconds);
        steps.after(Step.cleave, 8.seconds);
        steps.after(Step.tailSweep, 20.seconds);
        me.signalDungeon(BwlEncounter.vaelastrasz, EncounterState.inProgress);
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
            me.signalDungeon(BwlSignal.saveVael);
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
            // His departure uses the same saved clock as the scene.
            nefarius = me.summon(npcVictorNefarius, nefariusAtThrone);
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
            next = 8000;
            break;
        case 4:
            dismissCorruptor(me);
            break;
        default:
            break;
        }
        ++introPhase;
        if (next)
            steps.after(Step.intro, next.msecs);
        me.signalDungeon(BwlSignal.saveVael);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        dismissCorruptor(me);
        lowYelled = false;
        me.setHealthPercent(30);
        me.signalDungeon(BwlEncounter.vaelastrasz, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        dismissCorruptor(me);
        me.signalDungeon(BwlEncounter.vaelastrasz, EncounterState.done);
    }

    private void dismissCorruptor(ref CreatureContext me)
    {
        if (nefarius)
            me.despawn(nefarius);
        nefarius = EntityRef.init;
    }
}

/// Blackwing Lair's Suppression Room periodically pulses while Broodlord Lashlayer lives.
@gameObject("go_suppression")
struct SuppressionDevice
{
    enum Step : ubyte { pulse, rearm }
    Schedule!Step steps;

    void on(ref GameObjectContext device, const ref Spawned e)
    {
        if (device.askDungeon(BwlEncounter.lashlayer) == EncounterState.done)
            return shutdown(device);
        if (!steps.busy)
            steps.every(Step.pulse, (1 + device.random(5_000)).msecs, 5.seconds);
    }

    void on(ref GameObjectContext device, const ref Signal e)
    {
        if (e.id == BwlSignal.suppressionShutdown)
            shutdown(device);
    }

    void on(ref GameObjectContext device, const ref TrapSprung e)
    {
        device.consume(); // the fumes are periodic, even if everyone stands still
    }

    void on(ref GameObjectContext device, const ref TrapDisarmed e)
    {
        device.consume();
        disable(device);
        if (device.askDungeon(BwlEncounter.lashlayer) != EncounterState.done)
        {
            steps.after(Step.rearm, (30_000 + device.random(90_001)).msecs);
            device.signalDungeon(BwlSignal.suppressionDisarmed);
        }
    }

    void on(ref GameObjectContext device, Step step)
    {
        if (device.askDungeon(BwlEncounter.lashlayer) == EncounterState.done)
            return shutdown(device, step == Step.rearm);
        final switch (step)
        {
        case Step.pulse:
            device.customAnim();
            device.pulseTrap();
            break;
        case Step.rearm:
            device.open(false);
            device.objectFlags(device.self, ObjectFlag.noInteract, false);
            steps.every(Step.pulse, 5.seconds);
            device.signalDungeon(BwlSignal.suppressionFinished);
            break;
        }
    }

    private void shutdown(ref GameObjectContext device, bool rearming = false)
    {
        const disarmed = rearming || steps.pending(Step.rearm);
        disable(device);
        if (disarmed)
            device.signalDungeon(BwlSignal.suppressionFinished);
    }

    private void disable(ref GameObjectContext device)
    {
        steps.clear();
        device.open(true);
        device.objectFlags(device.self, ObjectFlag.noInteract, true);
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

    void on(ref CreatureContext me, const ref Died e) { steps.clear(); }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.signalDungeon(BwlEncounter.lashlayer, EncounterState.failed);
    }

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
        steps.after(Step.special, first.msecs);
        steps.after(Step.shadowFlame, 18.seconds);
        steps.after(Step.wingBuffet, 30.seconds);
        steps.after(Step.thrash, 6.seconds);
        me.signalDungeon(which, EncounterState.inProgress);
    }

    void on(ref CreatureContext me, const ref CreatureCastFinished e)
    {
        if (e.spell == shadowFlame || e.spell == wingBuffet)
            me.signalDungeon(BwlSignal.saveBossCombat);
    }

    static if (which == BwlEncounter.ebonroc)
        void on(ref CreatureContext me, const ref CreatureHealed e)
        {
            if (e.spell == ebonrocShadowHeal)
                me.signalDungeon(BwlSignal.saveBossCombat);
        }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.special:
            const ok = (special == shadowOfEbonroc ? me.castSpell(special) : me.castSelf(special)) == ActionResult.ok;
            if (ok && emote)
                me.say(emote);
            nextCombatStep(me, steps, step, ok, between(me, low, high));
            break;
        case Step.shadowFlame:
            nextCombatStep(me, steps, step, me.castSelf(shadowFlame) == ActionResult.ok, between(me, 15_000, 18_000));
            break;
        case Step.wingBuffet:
            const ok = me.castSelf(wingBuffet) == ActionResult.ok;
            if (ok)
            {
                EntityRef[40] near;
                foreach (p; near[0 .. me.playersNear(20, near[])])
                    me.modifyThreat(p, -50);
            }
            nextCombatStep(me, steps, step, ok, between(me, 30_000, 35_000));
            break;
        case Step.thrash:
            nextCombatStep(me, steps, step, me.castSelf(thrash) == ActionResult.ok, between(me, 2000, 6000));
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
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
    mixin Drake!(BwlEncounter.firemaw, flameBuffet, 5000, 5000, 5000) drake;
    alias steps = drake.steps;
    alias on = drake.on;
}

/// Ebonroc: the Shadow of Ebonroc on his foe.
@creature("boss_ebonroc")
struct Ebonroc
{
    mixin Drake!(BwlEncounter.ebonroc, shadowOfEbonroc, 45_000, 25_000, 35_000) drake;
    alias steps = drake.steps;
    alias on = drake.on;
}

/// Flamegor: frenzies.
@creature("boss_flamegor")
struct Flamegor
{
    mixin Drake!(BwlEncounter.flamegor, flamegorFrenzy, 10_000, 10_000, 15_000, -1_000_002) drake;
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
    enum : uint { bronze = 23170, timeStop = 23171, mutation = 23174, mutationStats = 23175, mutationSpeed = 23177 }
    static immutable uint[5] afflictions = [23153, 23154, 23155, 23169, bronze];
    enum Step : ubyte { shield, breathLeft, breathRight, affliction, frenzy }
    Schedule!Step steps;
    bool enraged;

    void on(ref CreatureContext me, const ref Died e) { steps.clear(); }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        enraged = false;
        me.signalDungeon(BwlEncounter.chromaggus, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.shield, 0.msecs);
        steps.after(Step.breathLeft, 30.seconds);
        steps.after(Step.breathRight, 60.seconds);
        steps.after(Step.affliction, 7.seconds);
        steps.after(Step.frenzy, 15.seconds);
        me.signalDungeon(BwlEncounter.chromaggus, EncounterState.inProgress);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after < 20)
        {
            enraged = true;
            me.castSelf(enrage);
            me.say(emoteFrenzy);
            me.signalDungeon(BwlSignal.saveBossCombat);
        }
    }

    static bool isRecoveryAura(uint spell)
    {
        import std.algorithm.searching : canFind;

        return afflictions[].canFind(spell) || spell == timeStop || spell == mutation
            || spell == mutationStats || spell == mutationSpeed;
    }

    private void afflict(ref CreatureContext me)
    {
        import std.algorithm.searching : all;

        const color = afflictions[me.random(afflictions.length)];
        EntityRef[120] targets; // a full raid and its pets and guardians
        const count = me.threatList(targets[]);
        size_t affected;
        foreach (target; targets[0 .. count])
        {
            if (!target.isPlayer || !me.alive(target) || me.hasAura(target, mutation))
                continue;
            me.castSpell(color, target, true);
            if (afflictions[].all!(spell => me.hasAura(target, spell)))
                if (me.castSpell(mutation, target, true) == ActionResult.ok && me.hasAura(target, mutation))
                {
                    foreach (spell; afflictions)
                        me.removeAura(target, spell);
                    me.castAs(target, mutationStats, target, true);
                    me.castAs(target, mutationSpeed, target, true);
                }
            if (++affected == 15)
                break;
        }
    }

    void on(ref CreatureContext me, const ref CreatureCastFinished e)
    {
        if (e.spell == me.askDungeon(BwlQuestion.chromaLeftBreath) || e.spell == me.askDungeon(BwlQuestion.chromaRightBreath))
            me.signalDungeon(BwlSignal.saveBossCombat);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shield:
            const shielded = me.castSelf(elementalShield) == ActionResult.ok;
            if (shielded)
                me.say(emoteShimmer);
            nextCombatStep(me, steps, step, shielded, 45.seconds);
            break;
        case Step.breathLeft, Step.breathRight:
            const breath = cast(uint) me.askDungeon(step == Step.breathLeft ? BwlQuestion.chromaLeftBreath
                : BwlQuestion.chromaRightBreath);
            nextCombatStep(me, steps, step, breath && me.castSelf(breath) == ActionResult.ok, 60.seconds);
            break;
        case Step.affliction:
            const afflicted = me.castSelf(broodAffliction) == ActionResult.ok;
            if (afflicted)
                afflict(me);
            nextCombatStep(me, steps, step, afflicted, 7.seconds);
            break;
        case Step.frenzy:
            const frenzied = me.castSelf(frenzy) == ActionResult.ok;
            if (frenzied)
                me.say(emoteFrenzyKill);
            nextCombatStep(me, steps, step, frenzied, 15.seconds);
            break;
        }
    }
}

/// Bronze Affliction periodically stuns the afflicted player.
@spell("spell_brood_affliction_bronze") @spellIds(Chromaggus.bronze)
struct BroodAfflictionBronze
{
    void on(ref SpellContext spell, const ref AuraTickEnded e)
    {
        if (e.effect == 0 && e.target.isPlayer && spell.random(10) == 0)
            spell.castSpell(e.target, Chromaggus.timeStop, e.target);
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
            me.unitFlags(UnitFlag.uninteractible, true);
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
        steps.after(Step.bolt, 3.seconds);
        steps.after(Step.fear, 8.seconds);
        steps.after(Step.volley, 13.seconds);
        steps.after(Step.silence, 23.seconds);
        steps.after(Step.command, 30.seconds);
        steps.after(Step.blink, 40.seconds);
        me.signalDungeon(BwlEncounter.nefarian, EncounterState.inProgress);
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
                me.unitFlags(UnitFlag.uninteractible, true);
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
        me.unitFlags(UnitFlag.uninteractible, false);
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
        me.signalDungeon(BwlSignal.saveNefarian);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (landed || e.point < 1 || e.point >= landing.length)
            return;
        if (e.point == 1)
            me.say(sayAggro);
        if (e.point + 1 < landing.length)
            me.moveTo(landing[e.point + 1], e.point + 1, true);
        else
        {
            landed = true;
            me.emote(293); // EMOTE_ONESHOT_LAND
            me.flying(false);
            steps.after(Step.attackStart, 4.seconds);
        }
        me.signalDungeon(BwlSignal.saveNefarian);
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
            me.unitFlags(UnitFlag.uninteractible, false);
            me.zoneCombat();
            if (const target = me.selectTarget(Pick.random))
                me.attack(target);
            steps.after(Step.shadowFlame, 12.seconds);
            steps.after(Step.roar, 30.seconds);
            steps.after(Step.veil, 15.seconds);
            steps.after(Step.cleave, 7.seconds);
            steps.after(Step.tailLash, 10.seconds);
            steps.after(Step.classCall, 35.seconds);
            me.signalDungeon(BwlSignal.saveNefarian);
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

/// The week's Chromaggus breaths and Nefarian's drakonids (`event_weekly_chromatic_selection`), and Razorgore
/// possessed through the Orb of Domination (`event_razorgore_possess`): the copy's script takes them
/// (`EventHappened`); the events' own scripts let them through to it.
/**
 * Spawn Drakonid (22659), the tick of a drakonid spawner's Drakonid Spawner (22653, every five seconds): the spawner
 * calls a drakonid of its colour (CMaNGOS's `Spell::EffectDummy` case: the spawners' EventAI casts only the chromatic
 * one, once a minute). Without it Nefarian's forty-two came in some twenty minutes.
 */
@spell("spell_spawn_drakonid") @spellIds(22659)
struct SpawnDrakonid
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        uint summon;
        switch (e.caster.entry)
        {
        case 14312: summon = 22658; break; // blue
        case 14310: summon = 22656; break; // green
        case 14311: summon = 22657; break; // bronze
        case 14309: summon = 22655; break; // red
        case 14307: summon = 22654; break; // black
        default: return;
        }
        it.castSpell(e.caster, summon, e.caster);
    }
}

@scriptedEvent("event_weekly_chromatic_selection", "event_razorgore_possess")
struct BlackwingLairEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
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
        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(entry) << 24) | summoned.length);
            return summoned[$ - 1];
        }
        override ActionResult hostDespawn(EntityRef c, uint) { despawned ~= c; return ActionResult.ok; }
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
        runtime.raise(h, c, ObjectUsedHere(bwlObject(goBlackDragonEgg, 20 + i), razorgore));
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
    {
        const drakonid = bwlCreature(14261, 100 + i);
        runtime.raise(h, c, CreatureLoaded(drakonid, true));
        runtime.raise(h, c, CreatureDied(drakonid, EntityRef(7)));
    }
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
    runtime.raise(h, me, CreatureCastFinished(Ebonroc.drake.shadowFlame));
    assert(host.dungeon[$ - 1].id == BwlSignal.saveBossCombat);
    runtime.raise(h, me, Died(EntityRef(7)));
    assert(!runtime.busy(h)); // the copy records defeat after the native spawn death is saved
}

/// The week's selection: a breath and a tunnel picked by its events, before the fights begin.
unittest
{
    alias self = dmangos.scripts.blackwinglair;
    auto runtime = ScriptRuntime.of!self();
    auto lair = new FakeLair;
    auto c = InstanceContext(lair);
    auto h = runtime.create(ScriptKind.instance, "instance_blackwing_lair");
    runtime.raise(h, c, EventHappened(8448, EntityRef.init, EntityRef.init)); // left: Time Lapse
    runtime.raise(h, c, EventHappened(8529, EntityRef.init, EntityRef.init)); // right tunnel: the blue
    runtime.raise(h, c, Asked(EntityRef.init, BwlQuestion.chromaLeftBreath));
    assert(c.answerGiven == 23310);
    runtime.raise(h, c, CreatureLoaded(bwlCreature(npcVictorNefarius, 4)));
    runtime.raise(h, c, Signal(EntityRef.init, BwlEncounter.nefarian, EncounterState.inProgress));
    assert(lair.summoned[1].entry == 14312);
}
