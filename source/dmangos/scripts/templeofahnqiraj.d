/**
 * The Temple of Ahn'Qiraj (map 531): the copy's script (its encounters and doors, the Twin Emperors'
 * introduction, Sartura's room, C'Thun's whispers), its area triggers, and the bosses: the Prophet
 * Skeram and his images, the Bug Trio (Lord Kri, Princess Yauj, Vem), Battleguard Sartura, Fankriss the
 * Unyielding, Viscidus and his globs, Princess Huhuran, the Twin Emperors, Ouro and his mounds, the Eye
 * of C'Thun and C'Thun, the Giant Claw Tentacle, and the Anubisath Sentinels and Defenders.
 *
 * In C'Thun's second phase his mouth tentacles seize players and he swallows them: his stomach (its
 * acid, its two Flesh Tentacles whose deaths weaken him, its way out, `at_stomach_cthun`) is here.
 */
module dmangos.scripts.templeofahnqiraj;

import core.time : Duration;

import dmangos.script;
import dmangos.script.state : appended;

/// Where `who` is, as `ctx` sees it (`Location.init` if it is not here).
private Location where(C)(ref C ctx, EntityRef who)
{
    Location at;
    ctx.locationOf(who, at);
    return at;
}

/// The copy's encounters (CMaNGOS's `TYPE_*`).
enum Aq40Encounter : ubyte
{
    skeram,
    bugTrio,
    sartura,
    fankriss,
    viscidus,
    huhuran,
    twins,
    ouro,
    cthun,
    twinsIntro,
}

/// Creatures and objects of the copy.
enum : uint
{
    npcSkeram = 15263,
    npcKri = 15511,
    npcVem = 15544,
    npcYauj = 15543,
    npcSartura = 15516,
    npcVeklor = 15276,
    npcVeknilash = 15275,
    npcMastersEye = 15963,
    npcOuroSpawner = 15957,
    npcOuro = 15517,
    npcDirtMound = 15712,
    npcOuroScarab = 15718,
    npcViscidus = 15299,
    npcGlobOfViscidus = 15667,
    npcEyeOfCthun = 15589,
    npcCthun = 15727,
    npcClawTentacle = 15725,
    npcEyeTentacle = 15726,
    npcGiantClawTentacle = 15728,
    npcGiantEyeTentacle = 15334,
    npcFleshTentacle = 15802,
    npcWorldTrigger = 15384,
    npcSpawnOfFankriss = 15630,
    npcVeknissHatchling = 15962,
    npcYaujBrood = 15621,
    npcQirajiScarab = 15316,
    npcQirajiScorpion = 15317,

    goSkeramGate = 180636,
    goTwinsEnterDoor = 180634,
    goTwinsExitDoor = 180635,
}

/// What scripts of the copy say to each other, beyond the encounters' states (ids 0 .. 9).
enum Aq40Signal : uint
{
    royalDown = 100,     /// the copy to the Bug Trio: one of them fell (`value`: how many have)
    image = 101,         /// Skeram to an image: you are one (`value`: its health in tenths of a percent)
    teleport = 102,      /// Skeram to an image: blink to place `value`
    twinHealth = 103,    /// a twin to the other: our health is now `value` percent
    twinSwap = 104,      /// Vek'lor to Vek'nilash: to where I stand
    twinDied = 105,      /// a twin to the other: I die; you too
    sentinelAbility = 106, /// a sentinel to another: your ability (`value`), or (dying) one more
    eyeDown = 107,       /// the Eye of C'Thun to C'Thun: the second phase
    ouroGone = 109,      /// Ouro to the spawner: wake again (the fight failed)
    cthunWhisper = 110,  /// the copy's tick: C'Thun whispers
    saveCthun = 111,     /// the Eye or C'Thun to the copy: a phase, a timer or the stomach changed (checkpoint me)
    resumeCthun = 112,   /// the copy to C'Thun: a player is back after a recovery
    stomachPlayer = 113, /// the copy to C'Thun: a player came back in the stomach (`value`: their guid)
    leftStomach = 114,   /// the stomach's way out to the copy: someone climbed out
    saveOuro = 115,      /// Ouro to the copy: his phase or timers changed (checkpoint me)
}

private enum uint triggerTwinEmperors = 4047, triggerSartura = 4052;

/// C'Thun's Check Reset spell's event (`event_cthun_reset`).
private enum uint cthunResetEvent = 9738;

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/// What every boss of the copy shares: its encounter under way, failed (home again), done.
private enum encounterOf(string which) = `
    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(` ~ which ~ `, EncounterState.inProgress);
        static if (__traits(hasMember, typeof(this), "engaged"))
            engaged(me, e);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(` ~ which ~ `, EncounterState.done);
        static if (__traits(hasMember, typeof(this), "died"))
            died(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.signalDungeon(` ~ which ~ `, EncounterState.failed);
        static if (__traits(hasMember, typeof(this), "reset"))
            reset(me);
    }
`;

/// What the copy remembers: its encounters (saved in `instance.data`).
@instance("instance_temple_of_ahnqiraj")
struct TempleOfAhnQiraj
{
    enum int[6] emperorsIntro = [-1_531_013, -1_531_014, -1_531_015, -1_531_016, -1_531_017, -1_531_018];
    enum uint emoteEyeIntro = 11_700;

    EncounterState[Aq40Encounter.max + 1] encounters;

    @transient EntityRef veklor, veknilash, mastersEye, sartura, cthun, eye, skeram;
    @transient EntityRef[3] trio;
    @transient EntityRef[3] doors; /// Skeram's gate, the Twins' doors in and out
    @transient ubyte trioDeaths, introStep;

    enum Step : ubyte { intro, whisper }
    Schedule!Step steps;

    // Appended to keep earlier lockout saves readable.
    @appended EntityRef[] cthunAdds; /// the tentacles living in C'Thun's fight under way (saved with it)
    @transient bool recoveringCthun, respawnEye;
    /// The Bug Trio devoured in their fight a worker's crash resumed (a bit for each of `trio`): they stay away.
    @transient ubyte trioDevoured;
    @transient bool recoveringTrio, recoveringTwins, recoveringOuro, wakeOuroSpawner;
    @transient EntityRef ouro, ouroSpawner;

    private static immutable uint[3] doorEntries = [goSkeramGate, goTwinsEnterDoor, goTwinsExitDoor];

    private bool doorOpen(size_t i) const
    {
        final switch (i)
        {
        case 0:
            return encounters[Aq40Encounter.skeram] == EncounterState.done;
        case 1:
            return encounters[Aq40Encounter.huhuran] == EncounterState.done
                && encounters[Aq40Encounter.twins] != EncounterState.inProgress;
        case 2:
            return encounters[Aq40Encounter.twins] == EncounterState.done;
        }
    }

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case npcVeklor, npcVeknilash:
            (e.creature.entry == npcVeklor ? veklor : veknilash) = e.creature;
            if (twinsActive && copy.alive(e.creature)) // a clean handoff: he stays in the checkpoint
                copy.checkpointCreature(e.creature);
            break;
        case npcOuro:
            if (!e.summoned)
                break;
            ouro = e.creature;
            if (ouroActive && copy.alive(ouro))
                copy.checkpointCreature(ouro);
            break;
        case npcOuroSpawner:
            ouroSpawner = e.creature;
            if (wakeOuroSpawner)
                copy.signal(ouroSpawner, Aq40Signal.ouroGone); // no Ouro of a fight lost: his sand wakes again
            break;
        case npcMastersEye:
            mastersEye = e.creature;
            break;
        case npcSartura:
            sartura = e.creature;
            break;
        case npcCthun:
            if (e.summoned)
                break;
            cthun = e.creature;
            if (!steps.pending(Step.whisper))
                steps.after(Step.whisper, 90.seconds);
            if (cthunActive) // a clean handoff brings him in without a signal: he stays in the checkpoint
                copy.checkpointCreature(cthun);
            break;
        case npcEyeOfCthun:
            if (e.summoned)
                break;
            eye = e.creature;
            if (cthunActive)
                copy.checkpointCreature(eye);
            break;
        case npcClawTentacle, npcEyeTentacle, npcGiantClawTentacle, npcGiantEyeTentacle, npcFleshTentacle:
            import std.algorithm.searching : canFind;

            if (e.summoned && cthunActive && !cthunAdds.canFind(e.creature))
            {
                cthunAdds ~= e.creature;
                copy.checkpointCreature(e.creature);
            }
            break;
        case npcSkeram:
            if (!skeram)
                skeram = e.creature;
            break;
        case npcKri, npcYauj, npcVem:
            if (!e.summoned)
                royalLoaded(copy, e.creature);
            break;
        default:
            break;
        }
    }

    // The Bug Trio --------------------------------------------------------------------------------------------------

    private static immutable uint[3] royalEntries = [npcKri, npcYauj, npcVem];

    private bool trioActive() const
    {
        return encounters[Aq40Encounter.bugTrio] == EncounterState.inProgress;
    }

    /**
     * One of the Bug Trio came into the copy. One devoured is not dead (it went), and its cell brings it back when it
     * loads again: in a fight a worker's crash resumed, or after the trio's end, it goes again at once.
     */
    private void royalLoaded(ref InstanceContext copy, EntityRef royal)
    {
        foreach (i, entry; royalEntries)
        {
            if (royal.entry != entry)
                continue;
            trio[i] = royal;
            const away = (trioActive && (trioDevoured & (1 << i)))
                || (encounters[Aq40Encounter.bugTrio] == EncounterState.done && !copy.killed(royal));
            if (away)
                copy.despawn(royal);
            else if (trioActive && copy.alive(royal)) // a clean handoff: it stays in the checkpoint
                copy.checkpointCreature(royal);
        }
    }

    /**
     * The Bug Trio's encounter in `state`. While it is under way those of them living are saved with the copy, so that
     * a worker's crash resumes the fight with the same ones (`Restored`): those devoured are not, and stay away. The
     * fight's count of the fallen starts from those away already (devoured in a fight before a wipe), so that the last
     * one standing still dies.
     */
    private void setTrio(ref InstanceContext copy, EncounterState state, EntityRef from = EntityRef.init)
    {
        const was = encounters[Aq40Encounter.bugTrio];
        if (was == EncounterState.inProgress && state == was && from.isCreature && copy.alive(from))
            return copy.checkpointCreature(from); // another of them joins: saved again, with its timers now
        if (was == state || was == EncounterState.done)
            return;
        encounters[Aq40Encounter.bugTrio] = state;
        if (state == EncounterState.inProgress)
        {
            trioDeaths = 0;
            foreach (royal; trio)
                if (royal && !copy.alive(royal))
                    ++trioDeaths;
                else if (royal)
                    copy.checkpointCreature(royal);
        }
        else
        {
            recoveringTrio = false;
            trioDevoured = 0;
            foreach (royal; trio)
                if (royal)
                    copy.releaseCheckpointActor(royal);
        }
        copy.checkpoint();
    }

    /// One of the three fell, devoured: the others are told (the second to fall is devoured too), and it is not saved.
    private void royalDevoured(ref InstanceContext copy, EntityRef royal)
    {
        ++trioDeaths;
        foreach (i, t; trio)
            if (t == royal)
                trioDevoured |= 1 << i;
        copy.releaseCheckpointActor(royal);
        foreach (t; trio)
            if (t && t != royal && copy.alive(t))
                copy.signal(t, Aq40Signal.royalDown, trioDeaths);
    }

    /// The copy came back from its save with the trio's fight under way: those saved with it are the living, and the
    /// others were devoured. A fight saved without any of them (an older save) has failed.
    private void restoreTrio(ref InstanceContext copy)
    {
        if (!trioActive)
            return;
        trioDevoured = 0;
        trioDeaths = 0;
        foreach (i, entry; royalEntries)
            if (!copy.hasSavedCreature(entry))
            {
                trioDevoured |= 1 << i;
                ++trioDeaths;
            }
        if (trioDeaths < royalEntries.length)
        {
            recoveringTrio = true;
            copy.waitForPlayer();
            return;
        }
        trioDevoured = 0;
        trioDeaths = 0;
        encounters[Aq40Encounter.bugTrio] = EncounterState.failed;
        copy.checkpoint();
    }

    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        foreach (i, entry; doorEntries)
            if (e.object.entry == entry)
            {
                doors[i] = e.object;
                copy.door(e.object, doorOpen(i));
            }
    }

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id <= Aq40Encounter.max)
            copy.answer(encounters[e.id]);
    }

    /// C'Thun's Check Reset found nobody left to fight (`event_cthun_reset`): his encounter has failed.
    void on(ref InstanceContext copy, const ref EventHappened e)
    {
        if (e.event != cthunResetEvent)
            return;
        copy.consume();
        if (cthunActive)
            setCthun(copy, EncounterState.failed);
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id == triggerTwinEmperors + 1000)
        {
            if (encounters[Aq40Encounter.twinsIntro] == EncounterState.notStarted)
            {
                encounters[Aq40Encounter.twinsIntro] = EncounterState.inProgress;
                introStep = 0;
                steps.after(Step.intro, 0.msecs);
            }
            return;
        }
        if (e.id == triggerSartura + 1000)
        {
            const s = encounters[Aq40Encounter.sartura];
            if ((s == EncounterState.notStarted || s == EncounterState.failed) && sartura)
                copy.zoneCombat(sartura);
            return;
        }
        if (e.id == Aq40Signal.saveCthun)
        {
            if (cthunActive && copy.alive(e.from))
                copy.checkpointCreature(e.from);
            return;
        }
        if (e.id == Aq40Signal.saveOuro)
        {
            if (ouroActive && copy.alive(e.from))
            {
                ouro = e.from;
                copy.checkpointCreature(e.from);
            }
            return;
        }
        if (e.id == Aq40Signal.leftStomach)
        {
            if (cthunActive)
                copy.checkpoint(); // where they came out, with the fight
            return;
        }
        if (e.id == Aq40Encounter.cthun)
        {
            if (e.from.isCreature && e.from.entry == npcCthun)
                cthun = e.from;
            else if (e.from.isCreature && e.from.entry == npcEyeOfCthun)
                eye = e.from;
            return setCthun(copy, cast(EncounterState) e.value);
        }
        if (e.id > Aq40Encounter.max)
            return;
        const which = cast(Aq40Encounter) e.id;
        const state = cast(EncounterState) e.value;
        if (which == Aq40Encounter.bugTrio)
        {
            if (state == EncounterState.special)
                royalDevoured(copy, e.from);
            else
                setTrio(copy, state, e.from);
            return;
        }
        if (which == Aq40Encounter.twins)
            return setTwins(copy, state, e.from);
        if (which == Aq40Encounter.ouro)
            return setOuro(copy, state, e.from);
        encounters[which] = state;
        updateDoors(copy);
    }

    private void updateDoors(ref InstanceContext copy)
    {
        foreach (i, d; doors)
            if (d)
                copy.door(d, doorOpen(i));
    }

    // The Twin Emperors and Ouro --------------------------------------------------------------------------------

    private bool twinsActive() const
    {
        return encounters[Aq40Encounter.twins] == EncounterState.inProgress;
    }

    private bool ouroActive() const
    {
        return encounters[Aq40Encounter.ouro] == EncounterState.inProgress;
    }

    /**
     * The Twin Emperors' encounter in `state`. While it is under way both are saved with the copy, so that a worker's
     * crash resumes their fight, the door in shut (`Restored`), even one that came before the first blow, which no
     * snapshot of a hurt creature holds.
     */
    private void setTwins(ref InstanceContext copy, EncounterState state, EntityRef from = EntityRef.init)
    {
        if (twinsActive && state == EncounterState.inProgress && from.isCreature && copy.alive(from))
            return copy.checkpointCreature(from); // his brother joins: saved again, with his timers now
        if (encounters[Aq40Encounter.twins] == state || encounters[Aq40Encounter.twins] == EncounterState.done)
            return;
        encounters[Aq40Encounter.twins] = state;
        foreach (twin; [veklor, veknilash])
            if (twin && twinsActive && copy.alive(twin))
                copy.checkpointCreature(twin);
            else if (twin && !twinsActive)
                copy.releaseCheckpointActor(twin);
        if (!twinsActive)
            recoveringTwins = false;
        updateDoors(copy);
        copy.checkpoint();
    }

    /**
     * Ouro's encounter in `state` (`from`: Ouro, when he tells it). He is a summon: while his fight is under way he is
     * saved with the copy, so that a worker's crash resumes it with him (`Restored`); a fight lost without him wakes
     * his sand again.
     */
    private void setOuro(ref InstanceContext copy, EncounterState state, EntityRef from)
    {
        if (from.isCreature && from.entry == npcOuro)
            ouro = from;
        const was = encounters[Aq40Encounter.ouro];
        if (was == state || was == EncounterState.done)
            return;
        encounters[Aq40Encounter.ouro] = state;
        if (ouroActive)
        {
            wakeOuroSpawner = false;
            if (ouro && copy.alive(ouro))
                copy.checkpointCreature(ouro);
        }
        else
        {
            recoveringOuro = false;
            if (ouro)
                copy.releaseCheckpointActor(ouro);
        }
        copy.checkpoint();
    }

    /// The copy came back from its save: the Twins' and Ouro's fights under way resume from the checkpoint when a
    /// player comes back; one saved without them (an older save, a crash before the checkpoint) has failed.
    private void restoreTwinsAndOuro(ref InstanceContext copy)
    {
        if (twinsActive)
        {
            if (copy.entryKilled(npcVeklor) && copy.entryKilled(npcVeknilash))
                encounters[Aq40Encounter.twins] = EncounterState.done; // their deaths landed, the save after did not
            else if (copy.hasSavedCreature(npcVeklor) || copy.hasSavedCreature(npcVeknilash))
            {
                recoveringTwins = true;
                copy.waitForPlayer();
            }
            else
                encounters[Aq40Encounter.twins] = EncounterState.failed; // the door in opens as it loads
            copy.checkpoint();
        }
        if (ouroActive && copy.hasSavedCreature(npcOuro))
        {
            recoveringOuro = true;
            copy.waitForPlayer();
            return;
        }
        if (ouroActive)
        {
            encounters[Aq40Encounter.ouro] = EncounterState.failed;
            copy.checkpoint();
        }
        // No Ouro: his sand, if a snapshot of it from his coming brought it back still, wakes again.
        wakeOuroSpawner = encounters[Aq40Encounter.ouro] != EncounterState.done;
    }

    /// A creature of the copy gave up its fight, or a checkpoint could not bring it back: its encounter has failed.
    void on(ref InstanceContext copy, const ref CreatureEvaded e)
    {
        switch (e.creature.entry)
        {
        case npcKri, npcYauj, npcVem:
            if (trioActive)
                setTrio(copy, EncounterState.failed);
            break;
        case npcVeklor, npcVeknilash:
            if (twinsActive)
                setTwins(copy, EncounterState.failed);
            break;
        case npcOuro:
            if (ouroActive)
            {
                setOuro(copy, EncounterState.failed, e.creature);
                if (ouroSpawner)
                    copy.signal(ouroSpawner, Aq40Signal.ouroGone);
            }
            break;
        default:
            break;
        }
    }

    private bool cthunActive() const
    {
        return encounters[Aq40Encounter.cthun] == EncounterState.inProgress;
    }

    /**
     * C'Thun's encounter in `state`. While it is under way the Eye, C'Thun and their living tentacles are saved
     * with the copy (a worker's crash resumes the fight, `Restored`); otherwise they are not, the tentacles go, and
     * a wipe after the Eye died brings the Eye back for the next pull.
     */
    private void setCthun(ref InstanceContext copy, EncounterState state)
    {
        if (encounters[Aq40Encounter.cthun] == EncounterState.done)
            return;
        encounters[Aq40Encounter.cthun] = state;
        if (cthunActive)
        {
            if (eye && copy.alive(eye))
                copy.checkpointCreature(eye);
            if (cthun && copy.alive(cthun))
                copy.checkpointCreature(cthun);
        }
        else
        {
            foreach (actor; [eye, cthun])
                if (actor)
                    copy.releaseCheckpointActor(actor);
            foreach (add; cthunAdds)
            {
                copy.releaseCheckpointActor(add);
                if (copy.alive(add))
                    copy.despawn(add);
            }
            cthunAdds = null;
            if (state == EncounterState.failed && copy.entryKilled(npcEyeOfCthun) && !copy.entryKilled(npcCthun))
                copy.respawnKilled(npcEyeOfCthun); // the next pull starts with the Eye
        }
        copy.checkpoint();
    }

    /// The copy came back from its save: C'Thun's fight under way resumes from its checkpoint when a player comes
    /// back; a fight saved without it fails, and an Eye slain in a fight that is over comes back.
    void on(ref InstanceContext copy, const ref Restored e)
    {
        import std.algorithm.mutation : remove;

        restoreTrio(copy);
        restoreTwinsAndOuro(copy);
        const state = encounters[Aq40Encounter.cthun];
        if (state == EncounterState.done)
            return;
        if (copy.entryKilled(npcCthun))
            return setCthun(copy, EncounterState.done);
        if (state == EncounterState.inProgress
                && (copy.hasSavedCreature(npcCthun) || copy.hasSavedCreature(npcEyeOfCthun)))
        {
            recoveringCthun = true;
            cthunAdds = cthunAdds.remove!(add => !copy.hasSavedCreature(add));
            copy.waitForPlayer();
            return;
        }
        if (state == EncounterState.inProgress)
        {
            encounters[Aq40Encounter.cthun] = EncounterState.failed; // older saves kept no fight to resume
            cthunAdds = null;
            copy.checkpoint();
        }
        if (copy.entryKilled(npcEyeOfCthun))
        {
            respawnEye = true; // once the copy is loaded
            copy.waitForPlayer();
        }
    }

    void on(ref InstanceContext copy, const ref PlayerEntered e)
    {
        // Back in a fight a crash resumed (the trio's, the Twins', Ouro's), each player joins it again.
        EntityRef[] resumed;
        if (recoveringTrio && trioActive)
            resumed ~= trio[];
        if (recoveringTwins && twinsActive)
            resumed ~= [veklor, veknilash];
        if (recoveringOuro && ouroActive)
            resumed ~= ouro;
        foreach (actor; resumed)
            if (actor && copy.alive(actor))
                copy.zoneCombat(actor);
        if (respawnEye)
        {
            respawnEye = false;
            if (!cthunActive && encounters[Aq40Encounter.cthun] != EncounterState.done
                    && copy.entryKilled(npcEyeOfCthun))
            {
                copy.respawnKilled(npcEyeOfCthun);
                copy.checkpoint();
            }
        }
        if (!cthunActive)
            return;
        if (recoveringCthun)
        {
            recoveringCthun = false;
            if (eye && copy.alive(eye) && !copy.alive(copy.victimOf(eye)))
                copy.zoneCombat(eye);
            foreach (add; cthunAdds)
                if (add.entry != npcFleshTentacle && copy.alive(add) && !copy.alive(copy.victimOf(add)))
                    copy.attack(add, e.player);
            if (cthun && copy.alive(cthun))
                copy.signal(cthun, Aq40Signal.resumeCthun);
        }
        if (cthun && copy.alive(cthun))
        {
            // Back in the stomach: C'Thun's acid finds them again (or, risen no more, he puts them out).
            Location at;
            if (copy.locationOf(e.player, at) && Cthun.insideStomach(at))
                copy.signal(cthun, Aq40Signal.stomachPlayer, cast(int) e.player.guid);
        }
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        if (!e.summoned && e.creature.entry == npcCthun)
            return setCthun(copy, EncounterState.done);
        if (!e.summoned && e.creature.entry == npcEyeOfCthun)
        {
            copy.releaseCheckpointActor(e.creature);
            return;
        }
        const index = cthunAdds.countUntil(e.creature);
        if (index < 0)
            return;
        cthunAdds = cthunAdds.remove(index);
        copy.releaseCheckpointActor(e.creature);
    }

    void on(ref InstanceContext copy, Step step)
    {
        final switch (step)
        {
        case Step.intro:
            // The Master's Eye looks on; the emperors rise and speak.
            uint next;
            if (introStep == 0)
            {
                if (mastersEye)
                    copy.despawn(mastersEye, 6000);
                next = 2000;
            }
            else if (introStep == 1)
                next = 6000;
            else if (introStep - 2 < emperorsIntro.length)
            {
                const i = introStep - 2;
                const speaker = i % 2 == 0 ? veklor : veknilash;
                if (speaker)
                    copy.say(speaker, emperorsIntro[i]);
                static immutable uint[6] gaps = [6000, 8000, 3000, 3000, 1000, 0];
                next = gaps[i];
                if (i == emperorsIntro.length - 1)
                    encounters[Aq40Encounter.twinsIntro] = EncounterState.done;
            }
            ++introStep;
            if (next)
                steps.after(Step.intro, next.msecs);
            break;
        case Step.whisper:
            // C'Thun whispers to someone in the temple, while he is not fought.
            const c = encounters[Aq40Encounter.cthun];
            if (cthun && c != EncounterState.inProgress && c != EncounterState.done)
            {
                EntityRef[40] players;
                const n = copy.players(players[]);
                if (n)
                    copy.say(cthun, -1_531_033 - cast(int) copy.random(8), players[copy.random(cast(uint) n)]);
            }
            steps.after(Step.whisper, (90_000 + copy.random(210_000)).msecs);
            break;
        }
    }
}

/// The temple's area triggers: the Twin Emperors' introduction, and Sartura's room.
@areaTrigger("at_temple_ahnqiraj")
struct AtTempleAhnQiraj
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (e.trigger == triggerTwinEmperors || e.trigger == triggerSartura)
            at.signalDungeon(1000 + e.trigger);
    }
}

/// C'Thun's Check Reset found nobody (`event_cthun_reset`): the copy's script fails his encounter
/// (`EventHappened`); the event's own script lets it through to it.
@scriptedEvent("event_cthun_reset")
struct CthunResetEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

/**
 * The way out of C'Thun's stomach: on the platform at its end (4033) a world trigger throws the player up
 * (Exit Stomach) and they come out at the ceiling (4034), above C'Thun; landing at his feet (4036) with his
 * Digestive Acid still on them, they are thrown back into the room.
 */
@areaTrigger("at_stomach_cthun")
struct AtStomachCthun
{
    enum uint platform = 4033, ceiling = 4034, feet = 4036;
    enum uint exitStomach = 26_221, exitStomachEffect = 26_230;

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        switch (e.trigger)
        {
        case platform:
            at.consume();
            if (const trigger = at.creatureNear(npcWorldTrigger, e.at, 30))
                at.castSpell(trigger, exitStomach, trigger);
            // Up and out (where the throw would carry them through the ceiling).
            at.teleport(e.player, Cthun.stomachExit);
            at.signalDungeon(Aq40Signal.leftStomach);
            break;
        case ceiling:
            at.consume();
            at.teleport(e.player, Cthun.stomachExit);
            at.signalDungeon(Aq40Signal.leftStomach);
            break;
        case feet:
            if (!at.hasAura(e.player, Cthun.digestiveAcid))
                return; // only those coming out of the stomach
            at.consume();
            if (const trigger = at.creatureNear(npcWorldTrigger, e.at, 30))
                at.castSpell(trigger, exitStomachEffect, e.player);
            break;
        default:
            break;
        }
    }
}

/**
 * The Prophet Skeram: Arcane Explosion when too many stand by him, True Fulfillment, Earth Shock at
 * whoever he cannot reach; he blinks between his three places, and at 75, 50 and 25% splits into
 * himself and two images (each a share of his health) that blink with him.
 */
@creature("boss_skeram")
struct Skeram
{
    enum : int { sayAggro = -1_531_000, sayDeath = -1_531_002 }
    enum uint slayText = 11_446;
    enum : uint { arcaneExplosion = 26_192, earthShock = 26_194, trueFulfillment = 785, birth = 26_262 }
    static immutable Location[3] places = [Location(-8344.97f, 2081.36f, 125.649f),
        Location(-8306.68f, 2060.84f, 133.062f), Location(-8330.63f, 2123.14f, 133.062f)];

    enum Step : ubyte { explosion, fulfillment, blink, earthShock, blinkDelay, initImages }
    Schedule!Step steps;
    bool isImage;
    ubyte hpCheck = 75;
    byte rangeChecks = -1;
    EntityRef[2] images;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(birth);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Aq40Signal.image)
        {
            isImage = true;
            me.setHealthPercent(e.value / 10 > 0 ? e.value / 10 : 1);
        }
        else if (e.id == Aq40Signal.teleport && e.value < places.length)
            blinkTo(me, places[e.value]);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!isImage)
        {
            me.say(sayAggro);
            me.signalDungeon(Aq40Encounter.skeram, EncounterState.inProgress);
            steps.after(Step.blink, between(me, 30_000, 45_000));
        }
        steps.after(Step.explosion, between(me, 6000, 12_000));
        steps.after(Step.fulfillment, 15.seconds);
        steps.after(Step.earthShock, 1200.msecs);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.sayText(slayText);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (isImage || e.after >= hpCheck || hpCheck < 25)
            return;
        // He splits: two images, each with its share of his health.
        hpCheck -= 25;
        despawnImages(me);
        const share = e.after < 25 ? 500 : e.after < 50 ? 200 : 100; // of his health, in tenths of a percent
        foreach (ref image; images)
        {
            image = me.summon(npcSkeram, me.location, 0, me.selectTarget(Pick.random));
            if (image)
                me.signal(image, Aq40Signal.image, share * e.after / 100);
        }
        me.melee(false);
        me.combatMovement(false);
        steps.after(Step.initImages, 1500.msecs);
    }

    private void despawnImages(ref CreatureContext me)
    {
        foreach (ref image; images)
            if (image)
            {
                me.despawn(image);
                image = EntityRef.init;
            }
    }

    /// He (or an image) is at `at`, his hatred forgotten, and fights on in a moment.
    private void blinkTo(ref CreatureContext me, Location at)
    {
        me.teleport(at);
        me.resetThreat();
        me.melee(false);
        me.combatMovement(false);
        steps.after(Step.blinkDelay, 2.seconds);
    }

    /// He and his images, each to one of the three places.
    private void blinkAll(ref CreatureContext me)
    {
        const first = me.random(3);
        blinkTo(me, places[first]);
        foreach (i, image; images)
            if (image && me.alive(image))
                me.signal(image, Aq40Signal.teleport, cast(int)((first + 1 + i) % 3));
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.explosion:
            // Only when enough stand beside him (one in ten of the raid, and one more).
            EntityRef[40] near;
            EntityRef[40] all;
            const raid = me.playersNear(200, all[]);
            if (me.playersNear(6, near[]) >= raid / 10 + 1 && me.castSelf(arcaneExplosion) == ActionResult.ok)
                steps.after(step, between(me, 8000, 18_000));
            else
                steps.after(step, 1.seconds);
            break;
        case Step.fulfillment:
            const target = me.selectTarget(Pick.nearest, PickFilter.player, 1);
            steps.after(step, target && me.castSpell(trueFulfillment, target) == ActionResult.ok
                ? between(me, 20_000, 30_000) : retry);
            break;
        case Step.blink:
            blinkAll(me);
            steps.after(step, between(me, 10_000, 30_000));
            break;
        case Step.earthShock:
            uint next = 500;
            if (me.selectTarget(Pick.topThreat, PickFilter.inMelee))
                rangeChecks = -1;
            else if (++rangeChecks > 1 && me.castSpell(earthShock) == ActionResult.ok)
                next = 2500;
            steps.after(step, next.msecs);
            break;
        case Step.blinkDelay:
            me.melee(true);
            me.combatMovement(true);
            if (const target = me.selectTarget(Pick.random))
                me.attack(target);
            break;
        case Step.initImages:
            blinkAll(me);
            steps.after(Step.blink, between(me, 30_000, 40_000));
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        hpCheck = 75;
        rangeChecks = -1;
        if (isImage)
            return me.despawn();
        despawnImages(me);
        me.signalDungeon(Aq40Encounter.skeram, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        if (isImage)
            return me.despawn(1);
        me.say(sayDeath);
        despawnImages(me);
        me.signalDungeon(Aq40Encounter.skeram, EncounterState.done);
    }
}

/**
 * What the Bug Trio share: none of them dies alone. The first two to fall are devoured by the survivors
 * (who heal fully and fight on), each leaving its parting gift (Kri a poison cloud, Vem his vengeance,
 * Yauj her brood); the last one dies.
 */
private mixin template Royalty()
{
    enum int emoteConsumed = -1_531_048;
    enum : uint { bloodyDeath = 25_770, fullHeal = 17_683, despawnBrood = 25_792 }
    bool consumed, last;

    /// Brought down, not dead: devoured.
    private void devoured(ref CreatureContext me)
    {
        consumed = true;
        me.signalDungeon(Aq40Encounter.bugTrio, EncounterState.special);
        me.say(emoteConsumed);
        me.standState(StandState.dead);
        me.melee(false);
        me.combatMovement(false);
        me.unitFlags(UnitFlag.uninteractible, true);
        deathAbility(me);
        me.castSelf(bloodyDeath, true);
        me.despawn(3000);
    }

    /// Its fight began: told to the copy last, once its timers are set (the copy saves it with them).
    private void royalEngaged(ref CreatureContext me)
    {
        me.signalDungeon(Aq40Encounter.bugTrio, EncounterState.inProgress);
    }

    private void royalSignal(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Aq40Signal.royalDown)
            return;
        // One of us fell: the last two may die now; heal from the feast.
        if (e.value >= 2)
        {
            last = true;
            me.deathPrevention(false);
        }
        me.castSelf(fullHeal, true);
    }

    private void royalDamaged(ref CreatureContext me, const ref Damaged e)
    {
        // Brought down while another lives: devoured (the last one simply dies).
        if (!consumed && !last && e.after == 0)
            devoured(me);
    }

    private void royalReset(ref CreatureContext me)
    {
        consumed = last = false;
        me.deathPrevention(true);
        me.standState(StandState.stand);
        me.melee(true);
        me.combatMovement(true);
        me.unitFlags(UnitFlag.uninteractible, false);
        me.castSelf(despawnBrood, true);
        me.signalDungeon(Aq40Encounter.bugTrio, EncounterState.failed);
    }

    private void royalDied(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        if (consumed)
            return;
        me.signalDungeon(Aq40Encounter.bugTrio, EncounterState.done);
        deathAbility(me);
    }
}

/// Lord Kri: Cleave, Toxic Volley, Thrash; leaves a poison cloud.
@creature("boss_kri")
struct Kri
{
    mixin Royalty;
    enum : uint { cleave = 26_350, toxicVolley = 25_812, summonCloud = 26_590, thrash = 3391 }
    enum Step : ubyte { cleave, volley, thrash }
    Schedule!Step steps;

    void deathAbility(ref CreatureContext me) { me.castSelf(summonCloud, true); }

    void on(ref CreatureContext me, const ref Spawned e) { me.deathPrevention(true); }
    void on(ref CreatureContext me, const ref Signal e) { royalSignal(me, e); }
    void on(ref CreatureContext me, const ref Damaged e) { royalDamaged(me, e); }
    void on(ref CreatureContext me, const ref Died e) { royalDied(me, e); }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        royalReset(me);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.cleave, between(me, 4000, 8000));
        steps.after(Step.volley, between(me, 6000, 30_000));
        steps.after(Step.thrash, 6.seconds);
        royalEngaged(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.cleave:
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? between(me, 5000, 12_000) : retry);
            break;
        case Step.volley:
            steps.after(step, me.castSelf(toxicVolley) == ActionResult.ok ? between(me, 15_000, 25_000) : retry);
            break;
        case Step.thrash:
            steps.after(step, me.castSelf(thrash) == ActionResult.ok ? between(me, 2000, 6000) : retry);
            break;
        }
    }
}

/// Vem: charges those beyond his reach, knocks away and down; his death enrages the others.
@creature("boss_vem")
struct Vem
{
    mixin Royalty;
    enum : uint { knockAway = 18_670, knockdown = 19_128, charge = 26_561, vengeance = 25_790 }
    enum Step : ubyte { charge, knockAway, knockdown }
    Schedule!Step steps;

    void deathAbility(ref CreatureContext me) { me.castSelf(vengeance, true); }

    void on(ref CreatureContext me, const ref Spawned e) { me.deathPrevention(true); }
    void on(ref CreatureContext me, const ref Signal e) { royalSignal(me, e); }
    void on(ref CreatureContext me, const ref Damaged e) { royalDamaged(me, e); }
    void on(ref CreatureContext me, const ref Died e) { royalDied(me, e); }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        royalReset(me);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.charge, between(me, 15_000, 27_000));
        steps.after(Step.knockAway, between(me, 10_000, 20_000));
        steps.after(Step.knockdown, between(me, 5000, 8000));
        royalEngaged(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.charge:
            const target = me.selectTarget(Pick.random, PickFilter.player | PickFilter.notInMelee);
            steps.after(step, target && me.castSpell(charge, target) == ActionResult.ok ? between(me, 8000, 16_000) : retry);
            break;
        case Step.knockAway:
            steps.after(step, me.castSpell(knockAway) == ActionResult.ok ? between(me, 10_000, 20_000) : retry);
            break;
        case Step.knockdown:
            steps.after(step, me.castSpell(knockdown) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        }
    }
}

/// Princess Yauj: heals herself, fears (her hatred forgotten), ravages; leaves her brood.
@creature("boss_yauj")
struct Yauj
{
    mixin Royalty;
    enum : uint { heal = 25_807, fear = 26_580, ravage = 3242, summonBrood = 25_789 }
    enum Step : ubyte { heal, fear, ravage }
    Schedule!Step steps;

    void deathAbility(ref CreatureContext me)
    {
        // Her brood: a few at her side, each at someone's throat.
        foreach (_; 0 .. 4)
            me.summon(npcYaujBrood, me.location, 0, me.selectTarget(Pick.random, PickFilter.player));
    }

    void on(ref CreatureContext me, const ref Spawned e) { me.deathPrevention(true); }
    void on(ref CreatureContext me, const ref Signal e) { royalSignal(me, e); }
    void on(ref CreatureContext me, const ref Damaged e) { royalDamaged(me, e); }
    void on(ref CreatureContext me, const ref Died e) { royalDied(me, e); }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        royalReset(me);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.heal, between(me, 20_000, 30_000));
        steps.after(Step.fear, between(me, 12_000, 24_000));
        steps.after(Step.ravage, 12.seconds);
        royalEngaged(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.heal:
            if (me.healthPercent < 100 && me.castSelf(heal) == ActionResult.ok)
                steps.after(step, between(me, 10_000, 30_000));
            else
                steps.after(step, 1.seconds);
            break;
        case Step.fear:
            if (me.castSelf(fear) == ActionResult.ok)
            {
                me.resetThreat();
                steps.after(step, 20.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.ravage:
            steps.after(step, me.castSpell(ravage) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        }
    }
}

/// Battleguard Sartura: whirlwinds, Sundering Cleave; enraged below a quarter, berserk after ten minutes.
@creature("boss_sartura")
struct Sartura
{
    enum : int { sayAggro = -1_531_008, sayDeath = -1_531_010, emoteFrenzy = -1_000_002, emoteBerserk = -1_000_004 }
    enum uint slayText = 11_443;
    enum : uint { enrage = 8269, sunderingCleave = 25_174, whirlwind = 26_083, berserk = 27_680 }
    enum Step : ubyte { whirlwind, cleave, berserk }
    Schedule!Step steps;
    bool enraged;

    mixin(encounterOf!"Aq40Encounter.sartura");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        steps.after(Step.whirlwind, between(me, 10_000, 20_000));
        steps.after(Step.cleave, between(me, 2000, 5000));
        steps.after(Step.berserk, 10 * 60.seconds);
    }

    void reset(ref CreatureContext me) { enraged = false; }
    void died(ref CreatureContext me) { me.say(sayDeath); }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.sayText(slayText);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after <= 25 && me.castSelf(enrage) == ActionResult.ok)
        {
            enraged = true;
            me.say(emoteFrenzy);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.whirlwind:
            if (me.castSelf(whirlwind) == ActionResult.ok)
            {
                // Whirling, she turns on whoever she will.
                me.resetThreat();
                if (const target = me.selectTarget(Pick.random, PickFilter.player))
                    me.addThreat(target, 100_000);
                steps.after(step, between(me, 20_000, 25_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.cleave:
            steps.after(step, me.castSpell(sunderingCleave) == ActionResult.ok ? between(me, 2000, 5000) : retry);
            break;
        case Step.berserk:
            if (me.castSelf(berserk) == ActionResult.ok)
                me.say(emoteBerserk);
            else
                steps.after(step, retry);
            break;
        }
    }
}

/// Fankriss the Unyielding: Mortal Wound, his spawn coming in waves, and entangling someone (with
/// hatchlings coming from the other two tunnels the first time).
@creature("boss_fankriss")
struct Fankriss
{
    enum : uint { mortalWound = 25_646 }
    static immutable uint[3] entangles = [720, 731, 1121];
    enum Step : ubyte { mortalWound, worm, entangle }
    Schedule!Step steps;
    ubyte wormsLeft;
    bool firstEntangle = true;
    EntityRef[12] spawns;

    mixin(encounterOf!"Aq40Encounter.fankriss");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        wormsLeft = cast(ubyte)(1 + me.random(3));
        firstEntangle = true;
        steps.after(Step.mortalWound, between(me, 10_000, 15_000));
        steps.after(Step.worm, between(me, 30_000, 50_000));
        steps.after(Step.entangle, between(me, 15_000, 20_000));
    }

    void reset(ref CreatureContext me)
    {
        foreach (ref s; spawns)
            if (s)
            {
                me.despawn(s);
                s = EntityRef.init;
            }
    }

    private void remember(EntityRef made)
    {
        foreach (ref s; spawns)
            if (!s)
            {
                s = made;
                return;
            }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.mortalWound:
            steps.after(step, me.castSpell(mortalWound) == ActionResult.ok ? between(me, 7000, 14_000) : retry);
            break;
        case Step.worm:
            remember(me.summon(npcSpawnOfFankriss, Location.init, 0, me.selectTarget(Pick.random)));
            if (--wormsLeft == 0)
            {
                wormsLeft = cast(ubyte)(1 + me.random(3));
                steps.after(step, between(me, 22_000, 70_000));
            }
            else
                steps.after(step, between(me, 5000, 7000));
            break;
        case Step.entangle:
            const target = me.selectTarget(Pick.random, PickFilter.player | PickFilter.notVictim);
            if (target && me.castSpell(entangles[me.random(3)], target) == ActionResult.ok)
            {
                if (firstEntangle)
                {
                    firstEntangle = false;
                    foreach (_; 0 .. 2)
                        remember(me.summon(npcVeknissHatchling, Location.init, 0, target));
                }
                steps.after(step, between(me, 25_000, 55_000));
            }
            else
                steps.after(step, retry);
            break;
        }
    }
}

/**
 * Viscidus: Poison Shock, Poisonbolt Volley, his toxin; frost slows him and at last freezes him solid,
 * and struck enough while frozen he shatters into globs that crawl back to him: those that make it are
 * his health when he rises again. He dies when too few return.
 */
@creature("boss_viscidus")
struct Viscidus
{
    enum : int
    {
        emoteSlow = -1_531_041,
        emoteFreeze = -1_531_042,
        emoteFrozen = -1_531_043,
        emoteCrack = -1_531_044,
        emoteShatter = -1_531_045,
        emoteExplode = -1_531_046,
    }
    enum : uint
    {
        poisonShock = 25_993,
        poisonboltVolley = 25_991,
        toxin = 26_575,
        slowed = 26_034,
        slowedMore = 26_036,
        freeze = 25_937,
        explode = 25_938,
        membrane = 25_994,
        invisSelf = 25_905,
    }
    enum ushort hitsSlow = 100, hitsSlowMore = 150, hitsFreeze = 200, hitsCrack = 50, hitsShatter = 100,
        hitsExplode = 150;
    enum uint frostMask = 16;
    enum Phase : ubyte { normal, slowed, slowedMore, frozen, exploded }

    enum Step : ubyte { toxin, shock, volley, thaw, rejoinCheck, rise }
    Schedule!Step steps;
    Phase phase;
    ushort hits;
    ubyte globsBack, globsOut;
    EntityRef[20] globs;

    mixin(encounterOf!"Aq40Encounter.viscidus");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!me.hasAura(me.self, membrane))
            me.castSelf(membrane, true);
        steps.after(Step.toxin, 30.seconds);
        steps.after(Step.shock, between(me, 7000, 12_000));
        steps.after(Step.volley, between(me, 10_000, 15_000));
    }

    void reset(ref CreatureContext me)
    {
        phase = Phase.normal;
        hits = 0;
        me.unitFlags(UnitFlag.uninteractible, false);
        me.rooted(false);
        me.melee(true);
        foreach (ref g; globs)
            if (g)
            {
                me.despawn(g);
                g = EntityRef.init;
            }
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (!(e.schoolMask & frostMask) || phase >= Phase.frozen)
            return;
        ++hits;
        if (phase == Phase.normal && hits >= hitsSlow)
        {
            phase = Phase.slowed;
            me.castSelf(slowed, true);
            me.say(emoteSlow);
        }
        else if (phase == Phase.slowed && hits >= hitsSlowMore)
        {
            phase = Phase.slowedMore;
            me.castSelf(slowedMore, true);
            me.say(emoteFreeze);
        }
        else if (phase == Phase.slowedMore && hits >= hitsFreeze)
        {
            phase = Phase.frozen;
            hits = 0;
            me.castSelf(freeze, true);
            me.say(emoteFrozen);
            steps.after(Step.thaw, 15.seconds);
        }
    }

    /// A glob slain does not come back to him. (Summoned to go when dead, a slain glob leaves the map at once, and
    /// `alive` of a creature not here says yes: without this he waited for his slain globs for ever.)
    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        foreach (ref g; globs)
            if (g == e.summoned)
                g = EntityRef.init;
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (phase != Phase.frozen)
            return;
        ++hits;
        if (hits == hitsCrack)
            me.say(emoteCrack);
        else if (hits == hitsShatter)
            me.say(emoteShatter);
        else if (hits >= hitsExplode)
            shatter(me, e.after);
    }

    /// He bursts into globs: as many as his health is worth (each five percent).
    private void shatter(ref CreatureContext me, uint health)
    {
        phase = Phase.exploded;
        steps.cancel(Step.thaw);
        me.say(emoteExplode);
        me.castSelf(explode, true);
        me.removeAura(me.self, freeze);
        me.unitFlags(UnitFlag.uninteractible, true);
        me.melee(false);
        me.rooted(true);
        me.resetThreat();
        globsOut = cast(ubyte)(health / 5);
        globsBack = 0;
        import std.math : cos, sin, PI;

        const at = me.location;
        foreach (i; 0 .. globsOut)
        {
            const angle = i * 2 * PI / globsOut;
            globs[i] = me.summon(npcGlobOfViscidus, Location(at.x + 30 * cos(angle), at.y + 30 * sin(angle), at.z));
            if (globs[i])
                me.moveCreature(globs[i], at, 0); // they crawl back to him
        }
        steps.after(Step.rejoinCheck, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.toxin:
            steps.after(step, me.castSelf(toxin) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.shock:
            if (phase < Phase.frozen && me.castSelf(poisonShock) == ActionResult.ok)
                steps.after(step, between(me, 7000, 12_000));
            else
                steps.after(step, retry);
            break;
        case Step.volley:
            if (phase < Phase.frozen && me.castSelf(poisonboltVolley) == ActionResult.ok)
                steps.after(step, between(me, 10_000, 15_000));
            else
                steps.after(step, retry);
            break;
        case Step.thaw:
            // Not shattered in time: he thaws.
            phase = Phase.normal;
            hits = 0;
            me.removeAura(me.self, freeze);
            me.removeAura(me.self, slowed);
            me.removeAura(me.self, slowedMore);
            break;
        case Step.rejoinCheck:
            // Each glob still alive and back at his side rejoins him.
            bool anyAlive;
            foreach (ref g; globs)
                if (g)
                {
                    if (!me.alive(g))
                    {
                        g = EntityRef.init;
                        continue;
                    }
                    // Not here (and so `alive`): a summon lost with a worker's crash, which he waited on for good. Not
                    // slain (its death would have freed its place), it rejoins him.
                    if (me.distanceTo(g) < 4 || me.distanceTo(g) == float.infinity)
                    {
                        ++globsBack;
                        me.despawn(g);
                        g = EntityRef.init;
                        continue;
                    }
                    anyAlive = true;
                }
            if (anyAlive)
                steps.after(step, 1.seconds);
            else
                steps.after(Step.rise, 1.seconds);
            break;
        case Step.rise:
            if (globsBack == 0)
                return me.die();
            phase = Phase.normal;
            hits = 0;
            me.setHealthPercent(globsBack * 5);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.rooted(false);
            me.melee(true);
            me.removeAura(me.self, slowed);
            me.removeAura(me.self, slowedMore);
            me.zoneCombat();
            break;
        }
    }
}

/// Princess Huhuran: Acid Spit, Noxious Poison, Wyvern Sting, frenzies; berserk below 30% or after five
/// minutes.
@creature("boss_huhuran")
struct Huhuran
{
    enum : int { emoteFrenzyKill = -1_000_001, emoteBerserk = -1_000_004 }
    enum : uint { frenzy = 26_051, berserk = 26_068, noxiousPoison = 26_053, wyvernSting = 26_180, acidSpit = 26_050 }
    enum Step : ubyte { berserk, frenzy, spit, poison, wyvern }
    Schedule!Step steps;
    bool berserked;

    mixin(encounterOf!"Aq40Encounter.huhuran");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.berserk, 5 * 60.seconds);
        steps.after(Step.frenzy, between(me, 25_000, 35_000));
        steps.after(Step.spit, 8.seconds);
        steps.after(Step.poison, between(me, 10_000, 20_000));
        steps.after(Step.wyvern, between(me, 35_000, 45_000));
    }

    void reset(ref CreatureContext me) { berserked = false; }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!berserked && e.after <= 30)
            steps.after(Step.berserk, 0.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.berserk:
            if (berserked)
                break;
            if (me.castSelf(berserk) == ActionResult.ok)
            {
                berserked = true;
                me.say(emoteBerserk);
                steps.cancel(Step.frenzy);
            }
            else
                steps.after(step, retry);
            break;
        case Step.frenzy:
            if (me.castSelf(frenzy) == ActionResult.ok)
            {
                me.say(emoteFrenzyKill);
                steps.after(step, between(me, 25_000, 35_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.spit:
            steps.after(step, me.castSpell(acidSpit) == ActionResult.ok ? between(me, 5000, 10_000) : retry);
            break;
        case Step.poison:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(noxiousPoison, target) == ActionResult.ok ? between(me, 12_000, 24_000) : retry);
            break;
        case Step.wyvern:
            steps.after(step, me.castSelf(wyvernSting) == ActionResult.ok ? between(me, 25_000, 35_000) : retry);
            break;
        }
    }
}

/**
 * What the Twin Emperors share: one life between them (each blow to one is felt by the other, and the
 * death of one is the death of both), healing each other when they stand too close, berserk after
 * fifteen minutes, and a bug ability on the scarabs and scorpions around.
 */
private mixin template Emperor(uint twin, uint bugSpell)
{
    enum uint healBrother = 7393, twinTeleportVisual = 26_638, twinTeleportStun = 800;
    bool dying;

    /// The other one.
    private EntityRef brother(ref CreatureContext me)
    {
        EntityRef[1] b;
        return me.creaturesNearby(twin, 200, b[]) ? b[0] : EntityRef.init;
    }

    private void emperorEngaged(ref CreatureContext me)
    {
        steps.after(Step.berserk, 15 * 60.seconds);
        steps.after(Step.bugAbility, between(me, 7000, 14_000));
        steps.after(Step.healCheck, 2.seconds);
    }

    /// His fight began: told to the copy last, once his timers are set (the copy saves him with them).
    private void emperorPulled(ref CreatureContext me)
    {
        me.signalDungeon(Aq40Encounter.twins, EncounterState.inProgress);
    }

    private void emperorDamaged(ref CreatureContext me, const ref Damaged e)
    {
        const b = brother(me);
        if (!b)
            return;
        if (e.after == 0)
            me.signal(b, Aq40Signal.twinDied);
        else if (me.healthPercentOf(b) > e.after)
            me.signal(b, Aq40Signal.twinHealth, e.after);
    }

    private void emperorSignal(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Aq40Signal.twinHealth && me.healthPercent > e.value)
            me.setHealthPercent(e.value);
        else if (e.id == Aq40Signal.twinDied && !dying)
        {
            dying = true;
            me.die();
        }
        else if (e.id == Aq40Signal.twinSwap)
        {
            // Vek'lor swaps places with me: to where he stands, my hatred forgotten, a moment stunned.
            if (const b = brother(me))
                me.teleport(where(me, b));
            stunned(me);
        }
    }

    /// Just teleported: hatred forgotten, a moment before it fights on.
    private void stunned(ref CreatureContext me)
    {
        me.resetThreat();
        me.castSelf(twinTeleportVisual, true);
        me.castSelf(twinTeleportStun, true);
        me.melee(false);
        me.combatMovement(false);
        steps.after(Step.teleportDelay, 2.seconds);
    }

    private void emperorStep(ref CreatureContext me, Step step)
    {
        switch (step)
        {
        case Step.berserk:
            if (me.castSelf(berserkSpell) != ActionResult.ok)
                steps.after(step, retry);
            break;
        case Step.bugAbility:
            EntityRef[8] bugs;
            size_t n = me.creaturesNearby(npcQirajiScarab, 50, bugs[0 .. 4]);
            n += me.creaturesNearby(npcQirajiScorpion, 50, bugs[n .. $]);
            if (n)
            {
                const bug = bugs[me.random(cast(uint) n)];
                me.castSpell(bugSpell, bug);
                static if (bugSpell == 802) // the mutated bug turns on the raid
                    if (const target = me.selectTarget(Pick.random, PickFilter.player))
                        me.attack(bug, target);
            }
            steps.after(step, between(me, 10_000, 17_000));
            break;
        case Step.teleportDelay:
            me.melee(meleeFighter);
            me.combatMovement(true);
            if (const target = me.selectTarget(Pick.nearest))
                me.attack(target);
            break;
        case Step.healCheck:
            // Too close together, they heal each other.
            const b = brother(me);
            if (b && me.distanceTo(b) < 60 && me.healthPercentOf(b) < 100)
                me.castSpell(healBrother, b);
            steps.after(step, 3.seconds);
            break;
        default:
            break;
        }
    }

    private void emperorReset(ref CreatureContext me)
    {
        steps.clear();
        dying = false;
        me.melee(meleeFighter);
        me.combatMovement(true);
        me.signalDungeon(Aq40Encounter.twins, EncounterState.failed);
    }

    private void emperorDied(ref CreatureContext me)
    {
        steps.clear();
        me.signalDungeon(Aq40Encounter.twins, EncounterState.done);
        if (!dying)
            if (const b = brother(me))
                me.signal(b, Aq40Signal.twinDied);
    }
}

/// Emperor Vek'nilash: the fighter. Uppercut, Unbalancing Strike; mutates bugs.
@creature("boss_veknilash")
struct Veknilash
{
    enum : int { sayAggro1 = -1_531_026, saySlay = -1_531_030, sayDeath = -1_531_031 }
    enum : uint { uppercut = 26_007, unbalancingStrike = 26_613, berserkSpell = 27_680, doubleAttack = 18_943 }
    enum bool meleeFighter = true;
    enum Step : ubyte { berserk, bugAbility, teleportDelay, healCheck, uppercut, unbalancing }
    Schedule!Step steps;

    mixin Emperor!(npcVeklor, 802);

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        emperorEngaged(me);
        me.say(sayAggro1 - cast(int) me.random(4));
        steps.after(Step.uppercut, between(me, 14_000, 29_000));
        steps.after(Step.unbalancing, between(me, 8000, 18_000));
        emperorPulled(me);
    }

    void on(ref CreatureContext me, const ref KilledUnit e) { me.say(saySlay); }
    void on(ref CreatureContext me, const ref Damaged e) { emperorDamaged(me, e); }
    void on(ref CreatureContext me, const ref Signal e) { emperorSignal(me, e); }
    void on(ref CreatureContext me, const ref Reset e) { emperorReset(me); }

    void on(ref CreatureContext me, const ref Died e)
    {
        me.say(sayDeath);
        emperorDied(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        switch (step)
        {
        case Step.uppercut:
            const target = me.selectTarget(Pick.random, PickFilter.inMelee);
            steps.after(step, target && me.castSpell(uppercut, target) == ActionResult.ok ? between(me, 15_000, 30_000) : retry);
            break;
        case Step.unbalancing:
            steps.after(step, me.castSpell(unbalancingStrike) == ActionResult.ok ? between(me, 8000, 20_000) : retry);
            break;
        default:
            emperorStep(me, step);
            break;
        }
    }
}

/// Emperor Vek'lor: the caster (no melee). Shadow Bolt, Blizzard, Arcane Burst at those beside him; every
/// 35 seconds he and his brother swap places; explodes bugs.
@creature("boss_veklor")
struct Veklor
{
    enum : int { sayAggro1 = -1_531_019, sayDeath = -1_531_024 }
    enum uint slayText = 11_453;
    enum : uint { shadowBolt = 26_006, blizzard = 26_607, arcaneBurst = 568, berserkSpell = 27_897 }
    enum bool meleeFighter = false;
    enum Step : ubyte { berserk, bugAbility, teleportDelay, healCheck, shadowBolt, blizzard, arcaneBurst, swap }
    Schedule!(Step, 10) steps;

    mixin Emperor!(npcVeknilash, 804);

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.melee(false);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        emperorEngaged(me);
        me.say(sayAggro1 - cast(int) me.random(4));
        steps.after(Step.shadowBolt, 1.seconds);
        steps.after(Step.blizzard, between(me, 15_000, 20_000));
        steps.after(Step.arcaneBurst, 1.seconds);
        steps.after(Step.swap, 35.seconds);
        emperorPulled(me);
    }

    void on(ref CreatureContext me, const ref KilledUnit e) { me.sayText(slayText); }
    void on(ref CreatureContext me, const ref Damaged e) { emperorDamaged(me, e); }
    void on(ref CreatureContext me, const ref Signal e) { emperorSignal(me, e); }
    void on(ref CreatureContext me, const ref Reset e) { emperorReset(me); }

    void on(ref CreatureContext me, const ref Died e)
    {
        me.say(sayDeath);
        emperorDied(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        switch (step)
        {
        case Step.shadowBolt:
            steps.after(step, me.castSpell(shadowBolt) == ActionResult.ok ? 2.seconds : retry);
            break;
        case Step.blizzard:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(blizzard, target) == ActionResult.ok ? between(me, 15_000, 30_000) : retry);
            break;
        case Step.arcaneBurst:
            if (me.selectTarget(Pick.topThreat, PickFilter.player | PickFilter.inMelee)
                    && me.castSelf(arcaneBurst) == ActionResult.ok)
                steps.after(step, 5.seconds);
            else
                steps.after(step, 1.seconds);
            break;
        case Step.swap:
            // He and his brother change places.
            if (const b = brother(me))
            {
                const his = where(me, b);
                me.signal(b, Aq40Signal.twinSwap); // he comes here first
                me.teleport(his);
                stunned(me);
            }
            steps.after(step, 35.seconds);
            break;
        default:
            emperorStep(me, step);
            break;
        }
    }
}

/**
 * Ouro: comes out of the sand where his spawner is disturbed; Sweep, Sand Blast (forgetting those hit),
 * boulders at those out of reach; every ninety seconds (or when nobody stands by him) he burrows, mounds
 * of dirt chasing his foes, and surfaces under one of them; berserk below a fifth.
 */
@creature("boss_ouro")
struct Ouro
{
    enum : uint
    {
        doubleAttack = 18_941,
        sweep = 26_103,
        sandBlast = 26_102,
        boulder = 26_616,
        berserk = 26_615,
        birth = 26_586,
        groundRupture = 26_100,
        submergeVisual = 26_063,
    }
    enum Step : ubyte { emerge, attack, submerge, boulder, sandBlast, sweep, doubleAttack, noMelee, resurface }
    Schedule!(Step, 10) steps;
    bool enraged, under;
    byte rangeChecks = -1;
    ubyte noMeleeCount;
    EntityRef[5] mounds;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.rooted(true);
        me.combatMovement(false);
        me.melee(false);
        steps.after(Step.emerge, 300.msecs); // before his fight begins: the copy saves him with it
        me.zoneCombat();
    }

    /// The copy saves him with his fight, as his phase or his timers change (a worker's crash resumes him there).
    private void checkpointMe(ref CreatureContext me)
    {
        me.signalDungeon(Aq40Signal.saveOuro);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Aq40Encounter.ouro, EncounterState.inProgress);
    }

    private void fightSteps(ref CreatureContext me)
    {
        steps.after(Step.submerge, 90.seconds);
        steps.after(Step.sandBlast, 25.seconds);
        steps.after(Step.sweep, 20.seconds);
        steps.after(Step.doubleAttack, between(me, 1000, 10_000));
        steps.after(Step.noMelee, 2.seconds);
        steps.after(Step.boulder, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after < 20 && me.castSelf(berserk) == ActionResult.ok)
        {
            enraged = true;
            steps.cancel(Step.submerge);
            steps.cancel(Step.noMelee);
            checkpointMe(me);
        }
    }

    /// Down into the sand: his mounds chase his foes; he comes up under one of them.
    private void burrow(ref CreatureContext me)
    {
        if (me.castSelf(submergeVisual) != ActionResult.ok)
            return;
        under = true;
        me.melee(false);
        me.unitFlags(UnitFlag.uninteractible, true);
        foreach (s; [Step.submerge, Step.noMelee, Step.sandBlast, Step.sweep, Step.boulder])
            steps.cancel(s);
        foreach (ref m; mounds)
            m = me.summon(npcDirtMound, me.location, 30_000, me.selectTarget(Pick.random, PickFilter.player));
        steps.after(Step.resurface, 30.seconds);
        checkpointMe(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.emerge:
            me.castSelf(birth);
            steps.after(Step.attack, 4.seconds);
            checkpointMe(me);
            break;
        case Step.attack:
            me.melee(true);
            me.unitFlags(UnitFlag.uninteractible, false);
            if (const target = me.selectTarget(Pick.nearest))
            {
                me.attack(target);
                me.castSpell(groundRupture, target);
            }
            fightSteps(me);
            checkpointMe(me);
            break;
        case Step.resurface:
            // Up under one of those his mounds chased.
            under = false;
            foreach (ref m; mounds)
                if (m)
                {
                    me.despawn(m);
                    m = EntityRef.init;
                }
            if (const prey = me.selectTarget(Pick.random, PickFilter.player))
                me.teleport(where(me, prey));
            me.resetThreat();
            steps.after(Step.emerge, 0.msecs);
            checkpointMe(me);
            break;
        case Step.submerge:
            burrow(me);
            break;
        case Step.sandBlast:
            if (me.castSelf(sandBlast) == ActionResult.ok)
            {
                if (const v = me.victim)
                    me.modifyThreat(v, -100);
                steps.after(step, 25.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.sweep:
            steps.after(step, me.castSelf(sweep) == ActionResult.ok ? 20.seconds : retry);
            break;
        case Step.doubleAttack:
            steps.after(step, me.castSelf(doubleAttack) == ActionResult.ok ? between(me, 7000, 13_000) : retry);
            break;
        case Step.boulder:
            uint next = 500;
            if (me.selectTarget(Pick.topThreat, PickFilter.inMelee))
                rangeChecks = -1;
            else if (++rangeChecks > 1)
                if (const target = me.selectTarget(Pick.random, PickFilter.player))
                    if (me.castSpell(boulder, target) == ActionResult.ok)
                        next = 2500;
            steps.after(step, next.msecs);
            break;
        case Step.noMelee:
            if (me.selectTarget(Pick.topThreat, PickFilter.inMelee))
                noMeleeCount = 0;
            else if (++noMeleeCount >= 10)
            {
                noMeleeCount = 0;
                burrow(me);
                break;
            }
            steps.after(step, 1.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        foreach (ref m; mounds)
            if (m)
            {
                me.despawn(m);
                m = EntityRef.init;
            }
        me.signalDungeon(Aq40Encounter.ouro, EncounterState.failed);
        EntityRef[1] spawner;
        if (me.creaturesNearby(npcOuroSpawner, 100, spawner[]))
            me.signal(spawner[0], Aq40Signal.ouroGone);
        me.despawn();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(Aq40Encounter.ouro, EncounterState.done);
    }
}

/// The Ouro Spawner: the sand where Ouro sleeps. Disturbed, it brings him up and is still while he lives.
@creature("npc_ouro_spawner")
struct OuroSpawner
{
    enum uint dirtmoundPassive = 26_092;
    bool summoned;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        me.melee(false);
    }

    /// A living player within 50 yards disturbs the sand (CMaNGOS's `MoveInLineOfSight`): the world data makes
    /// it one no player can strike, so coming near is the only way to begin his fight.
    void on(ref CreatureContext me, const ref UnitInSight e)
    {
        if (e.unit.isPlayer && me.alive(e.unit) && me.distanceTo(e.unit) <= 50)
            wake(me);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        wake(me);
    }

    private void wake(ref CreatureContext me)
    {
        if (summoned || me.askDungeon(Aq40Encounter.ouro) == EncounterState.done)
            return;
        summoned = true;
        me.summon(npcOuro, me.location);
        me.reactState(Reaction.passive);
        me.unitFlags(UnitFlag.uninteractible, true);
        me.evade();
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Aq40Signal.ouroGone)
            return;
        summoned = false;
        me.reactState(Reaction.aggressive);
        me.unitFlags(UnitFlag.uninteractible, false);
    }
}

/// A Dirt Mound of Ouro's: chases one player after another while he is under the sand.
@creature("npc_ouro_mound")
struct OuroMound
{
    enum uint dirtmoundPassive = 26_092;
    enum Step : ubyte { pick }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, dirtmoundPassive))
            me.castSelf(dirtmoundPassive, true);
        steps.after(Step.pick, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.zoneCombat();
        me.resetThreat();
        if (const target = me.selectTarget(Pick.random, PickFilter.player))
        {
            me.addThreat(target, 1_000_000);
            me.attack(target);
        }
        steps.after(step, between(me, 5000, 10_000));
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        me.despawn(1000);
    }
}

/// An Ouro Scarab: waits a moment, then goes for someone at random.
@creature("npc_ouro_scarab")
struct OuroScarab
{
    enum Step : ubyte { attack }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.defensive);
        steps.after(Step.attack, 4.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.reactState(Reaction.aggressive);
        me.zoneCombat();
        if (const target = me.selectTarget(Pick.random))
        {
            me.addThreat(target, 1_000_000);
            me.attack(target);
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        me.despawn(1000);
    }
}

/// The Ouro Trigger: still and passive (Ouro's resurfacing is his own script's here).
@creature("npc_ouro_trigger")
struct OuroTrigger
{
    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.combatMovement(false);
    }
}

/**
 * The Eye of C'Thun: Eye Beam at random foes, and every so often it turns red and sweeps its Dark Glare
 * round the room; claw tentacles rise under players and eye tentacles ring the room. When it dies,
 * C'Thun himself rises.
 */
@creature("boss_eye_of_cthun")
struct EyeOfCthun
{
    enum : uint { eyeBeam = 26_134, eyeBeamInit = 32_950, darkGlare = 26_029, rotateTrigger = 26_137 }
    enum Step : ubyte { beam, glare, endGlare, clawTentacle, eyeTentacles }
    Schedule!Step steps;
    ubyte initialBeams;
    bool glaring;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Aq40Encounter.cthun, EncounterState.inProgress);
        me.combatMovement(false);
        me.zoneCombat();
        initialBeams = 0;
        steps.after(Step.beam, 1.msecs);
        steps.after(Step.glare, 48.seconds);
        steps.after(Step.clawTentacle, 8.seconds);
        steps.after(Step.eyeTentacles, 45.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.beam:
            if (glaring)
            {
                steps.after(step, 1.seconds);
                break;
            }
            if (initialBeams < 3)
            {
                if (me.castSpell(eyeBeamInit) == ActionResult.ok)
                    ++initialBeams;
                steps.after(step, 2.seconds);
                break;
            }
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(eyeBeam, target) == ActionResult.ok ? between(me, 3000, 5000) : retry);
            break;
        case Step.glare:
            // Red: it turns to someone and sweeps the room.
            if (const target = me.selectTarget(Pick.random, PickFilter.player))
                me.face(target);
            me.castSelf(rotateTrigger, true);
            me.castSelf(darkGlare, true);
            glaring = true;
            steps.after(Step.endGlare, 40.seconds);
            steps.after(step, 80.seconds);
            break;
        case Step.endGlare:
            glaring = false;
            me.removeAura(me.self, darkGlare);
            break;
        case Step.clawTentacle:
            if (const target = me.selectTarget(Pick.random, PickFilter.player))
                me.summon(npcClawTentacle, where(me, target), 0, target);
            steps.after(step, 8.seconds);
            break;
        case Step.eyeTentacles:
            summonRing(me, npcEyeTentacle, 8, 35);
            steps.after(step, 45.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        glaring = false;
        me.signalDungeon(Aq40Encounter.cthun, EncounterState.failed);
        despawnTentacles(me);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        despawnTentacles(me);
        EntityRef[1] cthun;
        if (me.creaturesNearby(npcCthun, 50, cthun[]))
            me.signal(cthun[0], Aq40Signal.eyeDown);
    }
}

/// `count` creatures of `entry` in a ring of `radius` yards round `me`, each at someone's throat.
private void summonRing(ref CreatureContext me, uint entry, uint count, float radius)
{
    import std.math : cos, sin, PI;

    const at = me.location;
    foreach (i; 0 .. count)
    {
        const angle = i * 2 * PI / count;
        me.summon(entry, Location(at.x + radius * cos(angle), at.y + radius * sin(angle), at.z), 0,
            me.selectTarget(Pick.random, PickFilter.player));
    }
}

/// C'Thun's tentacles all gone (a wipe, or a phase over).
private void despawnTentacles(ref CreatureContext me)
{
    EntityRef[32] t;
    foreach (entry; [npcClawTentacle, npcEyeTentacle, npcGiantClawTentacle, npcGiantEyeTentacle, npcFleshTentacle])
        foreach (tentacle; t[0 .. me.creaturesNearby(entry, 250, t[])]) // the stomach's too
            me.despawn(tentacle);
}

/**
 * C'Thun: rises when his Eye dies, behind his carapace; giant claw and eye tentacles come in turn and eye
 * tentacles ring the room. Every ten seconds a mouth tentacle seizes a player and he swallows them: in his
 * stomach his Digestive Acid eats at them (a stack every five seconds) and two Flesh Tentacles grow; slaying
 * both weakens him for 45 seconds, when no tentacles come and nobody is swallowed. Those who climb out
 * (`at_stomach_cthun`) lose the acid. On a wipe those still inside are put out of the stomach (CMaNGOS kills
 * them).
 */
@creature("boss_cthun")
struct Cthun
{
    enum int emoteWeakened = 11_476; /// broadcast text
    enum : uint { carapace = 26_156, transform = 26_232, vulnerable = 26_235, mouthTentacle = 26_332, digestiveAcid = 26_476 }
    /// Where the swallowed land (Digestive Acid's teleport), and where those climbing out come up.
    static immutable Location stomach = Location(-8563.56f, 2040.69f, -97.0f, 4.9426f);
    static immutable Location stomachExit = Location(-8576.06f, 1985.8359f, 100.22033f, 6.108652f);
    /// The two Flesh Tentacles' places in the stomach.
    static immutable Location[2] fleshPlaces = [
        Location(-8571.472f, 1990.2048f, -98.777855f, 1.0123f), Location(-8525.083f, 1994.7125f, -98.255325f, 2.5831f),
    ];
    /// The lower chamber around the swallow point, Flesh Tentacles and exit platform.
    static bool insideStomach(P)(P at)
    {
        return at.z < 0 && (at.x - stomach.x) ^^ 2 + (at.y - stomach.y) ^^ 2 < 100 ^^ 2;
    }

    enum Step : ubyte { emerge, giantClaw, giantEye, eyeTentacles, mouth, swallow, acid, weakenedEnd }
    Schedule!Step steps;
    bool risen, weakened;
    ubyte fleshSlain;
    EntityRef seized;          /// the player a mouth tentacle holds, about to be swallowed
    EntityRef[40] inStomach;   /// those swallowed (empty slots: nothing)

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        me.reactState(Reaction.passive);
        me.unitFlags(UnitFlag.uninteractible, true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        switch (e.id)
        {
        case Aq40Signal.eyeDown:
            if (risen || steps.pending(Step.emerge))
                break;
            steps.after(Step.emerge, 5.seconds);
            me.signalDungeon(Aq40Signal.saveCthun); // his rise is saved with the Eye's death
            break;
        case Aq40Signal.resumeCthun:
            if (risen)
                me.zoneCombat();
            break;
        case Aq40Signal.stomachPlayer:
            const who = EntityRef(cast(uint) e.value);
            if (!risen)
            {
                // No fight to be in his stomach for: out.
                me.removeAura(who, digestiveAcid);
                me.teleport(who, stomachExit);
            }
            else if (!swallowedAlready(who))
            {
                foreach (ref slot; inStomach)
                    if (!slot)
                    {
                        slot = who;
                        me.signalDungeon(Aq40Signal.saveCthun);
                        break;
                    }
            }
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.summoned.entry != npcFleshTentacle || e.gone || !risen || weakened)
            return;
        if (++fleshSlain >= fleshPlaces.length)
            weaken(me);
        me.signalDungeon(Aq40Signal.saveCthun);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.emerge:
            risen = true;
            me.castSelf(transform, true);
            me.castSelf(carapace, true);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.reactState(Reaction.aggressive);
            me.zoneCombat();
            startTentacles(me);
            steps.every(Step.acid, 5.seconds);
            me.signalDungeon(Aq40Signal.saveCthun);
            break;
        case Step.giantClaw, Step.giantEye:
            if (const target = me.selectTarget(Pick.random, PickFilter.player))
                if (!swallowedAlready(target))
                    me.summon(step == Step.giantClaw ? npcGiantClawTentacle : npcGiantEyeTentacle, where(me, target), 0, target);
            steps.after(step, 60.seconds);
            break;
        case Step.eyeTentacles:
            summonRing(me, npcEyeTentacle, 8, 35);
            steps.after(step, 30.seconds);
            break;
        case Step.mouth:
            // A mouth tentacle seizes someone still in the room.
            foreach (attempt; 0 .. 3)
            {
                const target = me.selectTarget(Pick.random, PickFilter.player);
                if (!target || swallowedAlready(target) || target == seized)
                    continue;
                me.castSpell(mouthTentacle, target, true);
                seized = target;
                steps.after(Step.swallow, 4.seconds);
                break;
            }
            steps.after(step, 10.seconds);
            break;
        case Step.swallow:
            if (seized && me.alive(seized) && me.teleport(seized, stomach) == ActionResult.ok)
                foreach (ref slot; inStomach)
                    if (!slot)
                    {
                        slot = seized;
                        break;
                    }
            seized = EntityRef.init;
            me.signalDungeon(Aq40Signal.saveCthun); // the swallowed are saved in his stomach
            break;
        case Step.acid:
            // The acid eats at the swallowed; those who climbed out are rid of it. One not back yet after a
            // worker's crash keeps their place (the copy tells him where they come back, `stomachPlayer`).
            bool changed;
            foreach (ref who; inStomach)
            {
                if (!who)
                    continue;
                Location at;
                if (!me.locationOf(who, at))
                    continue;
                if (!me.alive(who))
                {
                    who = EntityRef.init;
                    changed = true;
                }
                else if (!insideStomach(at))
                {
                    me.removeAura(who, digestiveAcid);
                    who = EntityRef.init;
                    changed = true;
                }
                else
                    me.castSpell(digestiveAcid, who, true);
            }
            if (changed)
                me.signalDungeon(Aq40Signal.saveCthun);
            break;
        case Step.weakenedEnd:
            weakened = false;
            me.removeAura(me.self, vulnerable);
            me.castSelf(carapace, true);
            startTentacles(me);
            me.signalDungeon(Aq40Signal.saveCthun);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
        risen = weakened = false;
        despawnTentacles(me);
        foreach (ref who; inStomach)
            if (who)
            {
                me.removeAura(who, digestiveAcid);
                me.teleport(who, stomachExit);
                who = EntityRef.init;
            }
        seized = EntityRef.init;
        me.signalDungeon(Aq40Encounter.cthun, EncounterState.failed);
        me.reactState(Reaction.passive);
        me.unitFlags(UnitFlag.uninteractible, true);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        despawnTentacles(me);
        foreach (ref who; inStomach)
            if (who)
            {
                me.removeAura(who, digestiveAcid);
                who = EntityRef.init;
            }
        me.signalDungeon(Aq40Encounter.cthun, EncounterState.done);
    }

    /// The tentacles come (his rise, or the end of his weakness): giant ones, eye tentacles, mouths, and the
    /// two Flesh Tentacles in his stomach.
    private void startTentacles(ref CreatureContext me)
    {
        steps.after(Step.giantClaw, 10.seconds);
        steps.after(Step.giantEye, 40.seconds);
        steps.after(Step.eyeTentacles, 35.seconds);
        steps.after(Step.mouth, 10.seconds);
        fleshSlain = 0;
        EntityRef[fleshPlaces.length] growing;
        if (me.creaturesNearby(npcFleshTentacle, 250, growing[])) // the stomach's tentacles grow once
            return;
        foreach (place; fleshPlaces)
            me.summon(npcFleshTentacle, place);
    }

    /// Both Flesh Tentacles slain: his carapace falls for 45 seconds, and the tentacles stop.
    private void weaken(ref CreatureContext me)
    {
        weakened = true;
        me.sayText(emoteWeakened);
        me.removeAura(me.self, carapace);
        me.castSelf(vulnerable, true);
        foreach (s; [Step.giantClaw, Step.giantEye, Step.eyeTentacles, Step.mouth])
            steps.cancel(s);
        steps.after(Step.weakenedEnd, 45.seconds);
    }

    private bool swallowedAlready(EntityRef who) const
    {
        foreach (s; inStomach)
            if (s == who)
                return true;
        return false;
    }
}

/// A Giant Claw Tentacle of C'Thun's: Hamstring, Thrash and ground ruptures; when nobody is in its reach
/// it burrows and comes up under someone else.
@creature("mob_giant_claw_tentacle")
struct GiantClawTentacle
{
    enum : uint { giantGroundRupture = 26_478, hamstring = 26_211, thrash = 3391, groundTremor = 6524 }
    enum Step : ubyte { check, rupture, tremor }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        steps.after(Step.rupture, 2.seconds);
        steps.after(Step.tremor, 7.seconds);
        steps.after(Step.check, 5.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.rupture:
            me.castSelf(giantGroundRupture, true);
            break;
        case Step.tremor:
            me.castSelf(groundTremor);
            steps.after(step, between(me, 7000, 10_000));
            break;
        case Step.check:
            if (me.selectTarget(Pick.topThreat, PickFilter.inMelee))
            {
                me.castSpell(me.random(2) ? hamstring : thrash);
                steps.after(step, 5.seconds);
            }
            else if (const prey = inTheRoom(me))
            {
                // Under someone else (in the room: it cannot follow anyone into C'Thun's stomach).
                me.teleport(where(me, prey));
                me.resetThreat();
                me.attack(prey);
                steps.after(Step.rupture, 1.seconds);
                steps.after(step, 5.seconds);
            }
            else
                steps.after(step, 1.seconds);
            break;
        }
    }

    /// A random player it could come up under: one not in C'Thun's stomach (nothing, if none is in the room).
    private static EntityRef inTheRoom(ref CreatureContext me)
    {
        foreach (attempt; 0 .. 4)
            if (const prey = me.selectTarget(Pick.random, PickFilter.player))
                if (where(me, prey).z > 0)
                    return prey;
        return EntityRef.init;
    }
}

/**
 * The Anubisath Sentinels guard in fours: as one is engaged each takes one ability of nine; as one dies,
 * the others gain its ability; enraged below 30%.
 */
@creature("mob_anubisath_sentinel")
struct AnubisathSentinel
{
    enum int emoteFrenzy = -1_000_002, emoteSharePowers = -1_531_047;
    enum uint enrage = 8599;
    static immutable uint[9] abilities = [812, 2147, 2148, 2834, 9347, 13_022, 19_595, 21_737, 25_777];
    enum uint entry = 15_264;
    uint ability;
    bool enraged;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (ability)
            return;
        // The first of the four to fight shares the abilities out.
        uint[9] order = abilities;
        foreach (i; 0 .. order.length)
        {
            const j = i + me.random(cast(uint)(order.length - i));
            const t = order[i];
            order[i] = order[j];
            order[j] = t;
        }
        take(me, order[0]);
        EntityRef[4] buddies;
        foreach (i, b; buddies[0 .. me.creaturesNearby(entry, 80, buddies[])])
            me.signal(b, Aq40Signal.sentinelAbility, cast(int) order[1 + i]);
    }

    private void take(ref CreatureContext me, uint spell)
    {
        if (!ability)
            ability = spell;
        me.castSelf(spell, true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Aq40Signal.sentinelAbility)
            take(me, e.value);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after < 30 && me.castSelf(enrage) == ActionResult.ok)
        {
            enraged = true;
            me.say(emoteFrenzy);
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        // Its power to those still standing.
        EntityRef[4] buddies;
        const n = me.creaturesNearby(entry, 80, buddies[]);
        if (n && ability)
            me.say(emoteSharePowers);
        foreach (b; buddies[0 .. n])
            me.signal(b, Aq40Signal.sentinelAbility, cast(int) ability);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        ability = 0;
        enraged = false;
    }
}

/**
 * An Anubisath Defender: two of meteor or plague, shadow storm or thunderclap, a reflection, enrage or
 * explosion near death, and warriors or swarmguards summoned.
 */
@creature("mob_anubisath_defender")
struct AnubisathDefender
{
    enum int emoteFrenzy = -1_000_002;
    enum : uint { shadowStorm = 26_555, meteor = 26_558, enrage = 8269, explode = 25_698, reflectFireArcane = 13_022,
        reflectShadowFrost = 19_595, thunderclap = 26_554, plague = 26_556, npcWarrior = 15_537, npcSwarmguard = 15_538 }
    enum Step : ubyte { first, second, summon }
    Schedule!Step steps;
    uint spell1, spell2, reflect, last, summonEntry;
    bool done;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        draw(me);
    }

    private void draw(ref CreatureContext me)
    {
        spell1 = me.random(2) ? meteor : plague;
        spell2 = me.random(2) ? shadowStorm : thunderclap;
        reflect = me.random(2) ? reflectFireArcane : reflectShadowFrost;
        last = me.random(2) ? enrage : explode;
        summonEntry = me.random(2) ? npcWarrior : npcSwarmguard;
        done = false;
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(reflect);
        steps.after(Step.first, between(me, 6000, 10_000));
        steps.after(Step.second, between(me, 10_000, 15_000));
        steps.after(Step.summon, between(me, 8000, 12_000));
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (done || e.after >= 10)
            return;
        done = true;
        if (last == enrage)
        {
            me.castSelf(enrage);
            me.say(emoteFrenzy);
        }
        else
            me.castSelf(explode);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.first:
            const target = spell1 == plague ? me.selectTarget(Pick.random, PickFilter.player) : me.victim;
            steps.after(step, target && me.castSpell(spell1, target) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.second:
            steps.after(step, me.castSelf(spell2) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.summon:
            me.summon(summonEntry, Location.init, 0, me.victim);
            steps.after(step, between(me, 15_000, 20_000));
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

    class FakeQiraji : BlackHole!CreatureHost
    {
        uint entry = npcKri;
        uint[] casts;
        int[] said;
        Signal[] dungeon, signals;
        uint health = 100, flags;
        bool preventing, dead, despawning;
        StandState stand;
        EntityRef[] summoned;
        EntityRef other;

        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(entry) << 24)); }
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override ActionResult hostSay(int text, EntityRef) { said ~= text; return ActionResult.ok; }
        override void hostSignalDungeon(uint id, int value) { dungeon ~= Signal(EntityRef.init, id, value); }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override void hostDeathPrevention(bool on) { preventing = on; }
        override void hostStandState(StandState s) { stand = s; }
        override void hostDespawn(uint) { despawning = true; }
        override void hostDie() { dead = true; }
        override uint hostHealthPercent() { return health; }
        override uint hostHealthPercentOf(EntityRef) { return 100; }
        override void hostSetHealthPercent(EntityRef, uint p) { health = p; }
        override void hostUnitFlags(uint f, bool set) { flags = set ? flags | f : flags & ~f; }
        override size_t hostCreaturesNearby(uint e, float, EntityRef[] into)
        {
            if (!other || other.entry != e || into.length == 0)
                return 0;
            into[0] = other;
            return 1;
        }
        override EntityRef hostSummon(uint e, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(e) << 24) | summoned.length);
            return summoned[$ - 1];
        }
        override bool hostAlive(EntityRef who) { return true; }
        override float hostDistanceTo(EntityRef) { return 2; }
    }
}

/// The Bug Trio: the first two brought down are devoured (their gift left, the others healed); the last
/// may die, and it is the encounter's end.
unittest
{
    import std.algorithm.searching : canFind;

    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeQiraji;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_kri");
    runtime.raise(h, me, Spawned());
    assert(host.preventing);
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    // Brought down while the others live: devoured.
    runtime.raise(h, me, Damaged(EntityRef(7), 9000, 2, 0));
    assert(host.dungeon[$ - 1] == Signal(EntityRef.init, Aq40Encounter.bugTrio, EncounterState.special));
    assert(host.stand == StandState.dead && host.despawning && host.casts.canFind(Kri.summonCloud));

    // Another one: the last of three, it may die.
    auto host2 = new FakeQiraji;
    host2.entry = npcVem;
    auto me2 = CreatureContext(host2);
    auto h2 = runtime.create(ScriptKind.creature, "boss_vem");
    runtime.raise(h2, me2, Spawned());
    runtime.raise(h2, me2, EnteredCombat(EntityRef(7)));
    runtime.raise(h2, me2, Signal(EntityRef.init, Aq40Signal.royalDown, 1));
    assert(host2.preventing && host2.casts.canFind(Vem.fullHeal));
    runtime.raise(h2, me2, Signal(EntityRef.init, Aq40Signal.royalDown, 2));
    assert(!host2.preventing);
    runtime.raise(h2, me2, Damaged(EntityRef(7), 9000, 2, 0));
    assert(!host2.despawning, "not devoured: it dies");
    runtime.raise(h2, me2, Died(EntityRef(7)));
    assert(host2.dungeon[$ - 1] == Signal(EntityRef.init, Aq40Encounter.bugTrio, EncounterState.done));
}

/// The Twin Emperors share one life: a blow to one lowers the other, and the death of one kills both.
unittest
{
    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeQiraji;
    host.entry = npcVeknilash;
    host.other = EntityRef(0xF130_0000_0000_0002UL | (ulong(npcVeklor) << 24));
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_veknilash");
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.raise(h, me, Damaged(EntityRef(7), 900, 80, 70));
    assert(host.signals[$ - 1] == Signal(host.other, Aq40Signal.twinHealth, 70));
    runtime.raise(h, me, Signal(host.other, Aq40Signal.twinHealth, 60));
    assert(host.health == 60);
    runtime.raise(h, me, Signal(host.other, Aq40Signal.twinDied, 0));
    assert(host.dead);
}

/// Viscidus: frost slows and freezes him; struck enough while frozen, he shatters into globs (one for
/// every five percent of his health); those that crawl back are his health when he rises.
unittest
{
    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeQiraji;
    host.entry = npcViscidus;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_viscidus");
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    foreach (_; 0 .. 200)
        runtime.raise(h, me, SpellHit(EntityRef(7), 116, Viscidus.frostMask));
    assert(host.said[$ - 1] == Viscidus.emoteFrozen);
    foreach (_; 0 .. 150)
        runtime.raise(h, me, Damaged(EntityRef(7), 10, 50, 50));
    assert(host.said[$ - 1] == Viscidus.emoteExplode && host.summoned.length == 10);
    assert(host.flags & UnitFlag.uninteractible);
    // Every glob crawls back (the fake has them beside him at once): he rises with all of his health.
    foreach (_; 0 .. 30)
        runtime.tick(h, me, 100);
    assert(host.health == 50 && !(host.flags & UnitFlag.uninteractible));
}

/// C'Thun swallows whom his mouth tentacle seizes: the acid eats at them in his stomach and leaves them once
/// they are out; both Flesh Tentacles slain weaken him.
unittest
{
    import std.algorithm.searching : canFind;

    static class FakeCthun : FakeQiraji
    {
        EntityRef[] teleported, unaura;
        float z = -97;
        override EntityRef hostSelectTarget(Pick, uint, uint) { return EntityRef(7); }
        override ActionResult hostTeleportPlayer(EntityRef who, Location) { teleported ~= who; return ActionResult.ok; }
        override bool hostLocationOf(EntityRef, out Location at) { at = Location(Cthun.stomach.x, Cthun.stomach.y, z); return true; }
        override ActionResult hostRemoveAura(EntityRef who, uint) { unaura ~= who; return ActionResult.ok; }
    }

    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeCthun;
    host.entry = npcCthun;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_cthun");
    runtime.raise(h, me, Spawned());
    runtime.raise(h, me, Signal(EntityRef.init, Aq40Signal.eyeDown));
    runtime.tick(h, me, 5000);
    assert(host.casts.canFind(Cthun.transform) && host.summoned.length == 2, "risen, his flesh tentacles grow");
    const flesh = host.summoned.dup;
    runtime.tick(h, me, 10_000);
    assert(host.casts.canFind(Cthun.mouthTentacle) && host.teleported.length == 0, "seized");
    runtime.tick(h, me, 4000);
    assert(host.teleported == [EntityRef(7)], "swallowed");
    host.casts = null;
    runtime.tick(h, me, 5000);
    assert(host.casts.canFind(Cthun.digestiveAcid), "the acid eats at them");
    host.z = 100; // out of the stomach
    runtime.tick(h, me, 5000);
    assert(host.unaura == [EntityRef(7)]);

    runtime.raise(h, me, SummonedDied(flesh[0], EntityRef(7)));
    assert(!host.casts.canFind(Cthun.vulnerable));
    runtime.raise(h, me, SummonedDied(flesh[1], EntityRef(7)));
    assert(host.casts.canFind(Cthun.vulnerable), "weakened");
}

/// C'Thun asks the copy to save him at each change a worker's crash must not lose (his rise, a swallow, a Flesh
/// Tentacle slain); his saved state resumes the same fight: one rise, the same stomach, the same count of slain.
unittest
{
    import std.algorithm.searching : canFind, count;
    import dmangos.bytes : ByteReader, ByteWriter;

    static class FakeCthun : FakeQiraji
    {
        EntityRef[] teleported;
        bool here = true;
        size_t fleshAlive;
        override EntityRef hostSelectTarget(Pick, uint, uint) { return EntityRef(7); }
        override ActionResult hostTeleportPlayer(EntityRef who, Location) { teleported ~= who; return ActionResult.ok; }
        override bool hostLocationOf(EntityRef, out Location at) { at = Cthun.stomach; return here; }
        override size_t hostCreaturesNearby(uint e, float, EntityRef[] into)
        {
            if (e != npcFleshTentacle)
                return 0;
            foreach (i; 0 .. fleshAlive)
                into[i] = EntityRef(0xF130_0000_0000_0200UL | (ulong(e) << 24) | i);
            return fleshAlive;
        }
    }

    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeCthun;
    host.entry = npcCthun;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_cthun");
    runtime.raise(h, me, Spawned());
    runtime.raise(h, me, Signal(EntityRef.init, Aq40Signal.eyeDown));
    assert(host.dungeon.canFind!(s => s.id == Aq40Signal.saveCthun), "the Eye's death saves his rise");
    host.dungeon = null;
    runtime.raise(h, me, Signal(EntityRef.init, Aq40Signal.eyeDown));
    assert(!host.dungeon.length, "the Eye's death told again changes nothing");
    runtime.tick(h, me, 5000);
    assert(host.casts.count(Cthun.transform) == 1 && host.summoned.length == 2);
    runtime.tick(h, me, 10_000);
    runtime.tick(h, me, 4000);
    assert(host.teleported == [EntityRef(7)] && host.dungeon[$ - 1].id == Aq40Signal.saveCthun, "a swallow is saved");
    const flesh = host.summoned[0 .. 2].dup;
    host.dungeon = null;
    runtime.raise(h, me, SummonedDied(flesh[0], EntityRef(7)));
    assert(host.dungeon.canFind!(s => s.id == Aq40Signal.saveCthun), "a Flesh Tentacle's death is saved");

    // A worker's crash: his saved state on another node, the swallowed player not back yet.
    ByteWriter saved;
    runtime.save(h, saved);
    auto host2 = new FakeCthun;
    host2.entry = npcCthun;
    host2.here = false;
    host2.fleshAlive = 1;
    auto me2 = CreatureContext(host2);
    auto h2 = runtime.create(ScriptKind.creature, "boss_cthun");
    auto reader = ByteReader(saved.data);
    assert(runtime.load(h2, reader));
    runtime.raise(h2, me2, Signal(EntityRef.init, Aq40Signal.eyeDown));
    runtime.tick(h2, me2, 5000);
    assert(!host2.casts.canFind(Cthun.transform) && !host2.summoned.canFind!(s => s.entry == npcFleshTentacle),
        "no second rise and no new Flesh Tentacles");
    assert(!host2.casts.canFind(Cthun.digestiveAcid), "the swallowed player is not back yet");
    host2.here = true;
    runtime.tick(h2, me2, 5000);
    assert(host2.casts.canFind(Cthun.digestiveAcid), "back in his stomach, kept on his list: the acid again");
    runtime.raise(h2, me2, SummonedDied(flesh[1], EntityRef(7)));
    assert(host2.casts.canFind(Cthun.vulnerable), "the other tentacle's death weakens him: the first one's counted");

    // One who comes back in his stomach while he has not risen is put out.
    auto host3 = new FakeCthun;
    host3.entry = npcCthun;
    auto me3 = CreatureContext(host3);
    auto h3 = runtime.create(ScriptKind.creature, "boss_cthun");
    runtime.raise(h3, me3, Spawned());
    runtime.raise(h3, me3, Signal(EntityRef.init, Aq40Signal.stomachPlayer, 9));
    assert(host3.teleported == [EntityRef(9)]);
}

/// The copy's side of C'Thun's recovery: a fight saved with him resumes when a player is back (who, in the stomach,
/// is handed to him); a fight saved without him fails; an Eye slain in a fight that is over comes back, whether the
/// wipe was seen or a worker's crash came between.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;

    static class FakeTemple : BlackHole!InstanceHost
    {
        uint[] killed, respawned;
        Signal[] signals;
        EntityRef[] despawned;
        Location position;
        override bool hostEntryKilled(uint entry) { return killed.canFind(entry); }
        override void hostRespawnKilled(uint entry) { respawned ~= entry; }
        override bool hostAlive(EntityRef) { return true; }
        override bool hostLocationOf(EntityRef, out Location at) { at = position; return true; }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override ActionResult hostDespawn(EntityRef c, uint) { despawned ~= c; return ActionResult.ok; }
    }
    EntityRef creature(uint entry, uint spawn) { return EntityRef(0xF130_0000_0000_0000UL | (ulong(entry) << 24) | spawn); }

    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    const eye = creature(npcEyeOfCthun, 1), cthun = creature(npcCthun, 2);
    const flesh = creature(npcFleshTentacle, 0x100), claw = creature(npcClawTentacle, 0x101);

    // The fight under way, with two tentacles; the copy saved.
    auto copy = new FakeTemple;
    auto c = InstanceContext(copy);
    auto h = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
    runtime.raise(h, c, CreatureLoaded(eye));
    runtime.raise(h, c, CreatureLoaded(cthun));
    runtime.raise(h, c, Signal(eye, Aq40Encounter.cthun, EncounterState.inProgress));
    runtime.raise(h, c, CreatureLoaded(flesh, true));
    runtime.raise(h, c, CreatureLoaded(claw, true));
    runtime.raise(h, c, CreatureLoaded(flesh, true));
    ByteWriter saved;
    runtime.save(h, saved);

    // A worker's crash, C'Thun and one tentacle in the checkpoint: the fight resumes as a player comes back.
    auto copy2 = new FakeTemple;
    copy2.killed = [npcEyeOfCthun];
    copy2.position = Cthun.stomach;
    auto c2 = InstanceContext(copy2);
    auto h2 = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
    auto reader = ByteReader(saved.data);
    assert(runtime.load(h2, reader));
    c2.savedSummons = [cthun, flesh];
    runtime.raise(h2, c2, Restored());
    assert(c2.waitingForPlayer && !copy2.respawned.length);
    runtime.raise(h2, c2, CreatureLoaded(cthun));
    runtime.raise(h2, c2, CreatureLoaded(flesh, true));
    runtime.raise(h2, c2, PlayerEntered(EntityRef(7)));
    assert(copy2.signals.canFind(Signal(cthun, Aq40Signal.resumeCthun, 0)));
    assert(copy2.signals.canFind(Signal(cthun, Aq40Signal.stomachPlayer, 7)), "back in the stomach: told to C'Thun");
    copy2.position = Location(-9024, 1176, -104); // Twin Emperors
    runtime.raise(h2, c2, PlayerEntered(EntityRef(8)));
    assert(!copy2.signals.canFind(Signal(cthun, Aq40Signal.stomachPlayer, 8)));
    assert(!copy2.respawned.length && !copy2.despawned.length);
    runtime.raise(h2, c2, Signal(cthun, Aq40Encounter.cthun, EncounterState.failed));
    assert(copy2.despawned == [flesh], "the wipe takes the restored tentacle, not the one lost with the worker");
    assert(copy2.respawned == [npcEyeOfCthun], "the wipe brings the Eye back");

    // A save without the fight's creatures (older, or lost): the fight failed; the slain Eye comes back.
    auto copy3 = new FakeTemple;
    copy3.killed = [npcEyeOfCthun];
    auto c3 = InstanceContext(copy3);
    auto h3 = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
    reader = ByteReader(saved.data);
    assert(runtime.load(h3, reader));
    runtime.raise(h3, c3, Restored());
    assert(c3.waitingForPlayer && !copy3.respawned.length, "the Eye waits for the copy to be loaded");
    runtime.raise(h3, c3, PlayerEntered(EntityRef(7)));
    assert(copy3.respawned == [npcEyeOfCthun] && !copy3.signals.length);
    runtime.raise(h3, c3, PlayerEntered(EntityRef(8)));
    assert(copy3.respawned == [npcEyeOfCthun], "once");
    auto asked3 = InstanceContext(copy3);
    runtime.raise(h3, asked3, Asked(EntityRef.init, Aq40Encounter.cthun));
    assert(asked3.answerGiven == EncounterState.failed);

    // A crash after the wipe was saved but before the Eye was back.
    runtime.raise(h2, c2, Signal(cthun, Aq40Encounter.cthun, EncounterState.failed));
    ByteWriter wiped;
    runtime.save(h2, wiped);
    auto copy5 = new FakeTemple;
    copy5.killed = [npcEyeOfCthun];
    auto c5 = InstanceContext(copy5);
    auto h5 = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
    reader = ByteReader(wiped.data);
    assert(runtime.load(h5, reader));
    runtime.raise(h5, c5, Restored());
    runtime.raise(h5, c5, PlayerEntered(EntityRef(7)));
    assert(copy5.respawned == [npcEyeOfCthun], "the Eye back after a crash between the wipe and its return");

    // C'Thun slain before the crash: the encounter is done, nothing comes back.
    auto copy4 = new FakeTemple;
    copy4.killed = [npcEyeOfCthun, npcCthun];
    auto c4 = InstanceContext(copy4);
    auto h4 = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
    reader = ByteReader(saved.data);
    assert(runtime.load(h4, reader));
    c4.savedSummons = [cthun];
    runtime.raise(h4, c4, Restored());
    runtime.raise(h4, c4, PlayerEntered(EntityRef(7)));
    auto asked = InstanceContext(copy4);
    runtime.raise(h4, asked, Asked(EntityRef.init, Aq40Encounter.cthun));
    assert(asked.answerGiven == EncounterState.done && !copy4.respawned.length && !copy4.signals.length);
}

/// A Giant Claw Tentacle with nobody in reach comes up under someone in the room, never in C'Thun's stomach.
unittest
{
    static class FakeClaw : FakeQiraji
    {
        float z = -97;
        Location[] went;
        override EntityRef hostSelectTarget(Pick pick, uint, uint)
        {
            return pick == Pick.random ? EntityRef(7) : EntityRef.init; // nobody in its reach
        }
        override bool hostLocationOf(EntityRef, out Location at) { at = Location(Cthun.stomach.x, Cthun.stomach.y, z); return true; }
        override void hostTeleport(Location at) { went ~= at; }
    }

    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeClaw;
    host.entry = npcGiantClawTentacle;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "mob_giant_claw_tentacle");
    runtime.raise(h, me, Spawned());
    runtime.tick(h, me, 5000);
    assert(!host.went.length, "it followed a swallowed player into the stomach");
    host.z = 100;
    runtime.tick(h, me, 1000);
    assert(host.went.length == 1 && host.went[0].z == 100);
}

/**
 * The copy's side of the Bug Trio's, the Twin Emperors' and Ouro's recovery: under way, those living are saved with
 * the copy; restored, they wait for the raid and each player back joins their fight, those of the trio devoured stay
 * away and the count of the fallen goes on; a fight saved without them has failed, and Ouro's sand wakes again.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;

    static class FakeChambers : BlackHole!InstanceHost
    {
        uint[] killed;
        EntityRef[] gone, despawned, zoned;
        Signal[] signals;
        override bool hostAlive(EntityRef c) { return !gone.canFind(c); }
        override bool hostEntryKilled(uint entry) { return killed.canFind(entry); }
        override bool hostKilled(EntityRef c) { return killed.canFind(c.entry); }
        override ActionResult hostDespawn(EntityRef c, uint)
        {
            despawned ~= c;
            gone ~= c;
            return ActionResult.ok;
        }
        override ActionResult hostZoneCombat(EntityRef c) { zoned ~= c; return ActionResult.ok; }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
    }
    EntityRef creature(uint entry, uint spawn) { return EntityRef(0xF130_0000_0000_0000UL | (ulong(entry) << 24) | spawn); }

    alias self = dmangos.scripts.templeofahnqiraj;
    auto runtime = ScriptRuntime.of!self();
    const kri = creature(npcKri, 1), yauj = creature(npcYauj, 2), vem = creature(npcVem, 3);
    const lor = creature(npcVeklor, 4), nilash = creature(npcVeknilash, 5);
    const spawner = creature(npcOuroSpawner, 6), ouro = creature(npcOuro, 0x100);
    int ask(FakeChambers room, typeof(runtime.create(ScriptKind.instance, "")) of, Aq40Encounter which)
    {
        auto c = InstanceContext(room);
        runtime.raise(of, c, Asked(EntityRef.init, which));
        return c.answerGiven;
    }
    auto restoredFrom(FakeChambers room, const(ubyte)[] saved, const(EntityRef)[] summons, out bool waiting)
    {
        auto h = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
        auto reader = ByteReader(saved);
        assert(runtime.load(h, reader));
        auto c = InstanceContext(room);
        c.savedSummons = summons;
        runtime.raise(h, c, Restored());
        waiting = c.waitingForPlayer;
        return h;
    }

    // The three fights under way; Kri devoured.
    auto room = new FakeChambers;
    auto h = runtime.create(ScriptKind.instance, "instance_temple_of_ahnqiraj");
    {
        auto c = InstanceContext(room);
        foreach (actor; [kri, yauj, vem, lor, nilash, spawner])
            runtime.raise(h, c, CreatureLoaded(actor));
        runtime.raise(h, c, Signal(kri, Aq40Encounter.bugTrio, EncounterState.inProgress));
        assert(c.checkpointSummons == [kri, yauj, vem] && c.checkpointRequested, "the trio's pull saves the three");
    }
    {
        auto c = InstanceContext(room);
        runtime.raise(h, c, Signal(kri, Aq40Encounter.bugTrio, EncounterState.special));
        assert(c.releasedCheckpointActors == [kri] && c.checkpointRequested, "the devoured still saved");
        assert(room.signals == [Signal(yauj, Aq40Signal.royalDown, 1), Signal(vem, Aq40Signal.royalDown, 1)]);
    }
    {
        auto c = InstanceContext(room);
        runtime.raise(h, c, Signal(lor, Aq40Encounter.twins, EncounterState.inProgress));
        runtime.raise(h, c, Signal(nilash, Aq40Encounter.twins, EncounterState.inProgress));
        assert(c.checkpointSummons == [lor, nilash, nilash], "the twins' pull saves them, the second again as he joins");
        runtime.raise(h, c, CreatureLoaded(ouro, true));
        runtime.raise(h, c, Signal(ouro, Aq40Encounter.ouro, EncounterState.inProgress));
        runtime.raise(h, c, Signal(ouro, Aq40Signal.saveOuro));
        assert(c.checkpointSummons == [lor, nilash, nilash, ouro, ouro], "Ouro not saved with his fight");
    }
    ByteWriter saved;
    runtime.save(h, saved);

    // A worker's crash: Yauj, Vem, the twins and Ouro in the checkpoint; Kri, devoured, comes with his cell and goes.
    auto room2 = new FakeChambers;
    bool waiting;
    auto h2 = restoredFrom(room2, saved.data, [yauj, vem, lor, nilash, ouro], waiting);
    assert(waiting);
    {
        auto c = InstanceContext(room2);
        foreach (actor; [kri, yauj, vem, lor, nilash, spawner])
            runtime.raise(h2, c, CreatureLoaded(actor));
        runtime.raise(h2, c, CreatureLoaded(ouro, true));
        runtime.raise(h2, c, PlayerEntered(EntityRef(7)));
    }
    assert(room2.despawned == [kri], "the devoured Kri back");
    foreach (actor; [yauj, vem, lor, nilash, ouro])
        assert(room2.zoned.canFind(actor), "the player back does not join the fight it resumed");
    assert(!room2.zoned.canFind(kri) && !room2.signals.canFind!(s => s.id == Aq40Signal.ouroGone));
    foreach (which; [Aq40Encounter.bugTrio, Aq40Encounter.twins, Aq40Encounter.ouro])
        assert(ask(room2, h2, which) == EncounterState.inProgress);
    {
        auto c = InstanceContext(room2);
        runtime.raise(h2, c, Signal(vem, Aq40Encounter.bugTrio, EncounterState.special));
    }
    assert(room2.signals.canFind(Signal(yauj, Aq40Signal.royalDown, 2)), "Yauj not told she is the last");
    {
        auto c = InstanceContext(room2);
        room2.killed ~= npcYauj;
        runtime.raise(h2, c, Signal(yauj, Aq40Encounter.bugTrio, EncounterState.done));
        assert(c.releasedCheckpointActors.canFind(yauj));
    }

    // After the trio's end, the devoured come with their cells and go again.
    ByteWriter ended;
    runtime.save(h2, ended);
    auto room3 = new FakeChambers;
    room3.killed = [npcYauj];
    auto h3 = restoredFrom(room3, ended.data, [lor, nilash, ouro], waiting);
    {
        auto c = InstanceContext(room3);
        foreach (actor; [kri, yauj, vem])
            runtime.raise(h3, c, CreatureLoaded(actor));
    }
    assert(room3.despawned == [kri, vem] && ask(room3, h3, Aq40Encounter.bugTrio) == EncounterState.done);

    // A save without them (an older one, or a crash before the checkpoint): the fights failed; Ouro's sand wakes.
    auto room4 = new FakeChambers;
    auto h4 = restoredFrom(room4, saved.data, null, waiting);
    foreach (which; [Aq40Encounter.bugTrio, Aq40Encounter.twins, Aq40Encounter.ouro])
        assert(ask(room4, h4, which) == EncounterState.failed);
    {
        auto c = InstanceContext(room4);
        foreach (actor; [kri, yauj, vem, lor, nilash, spawner])
            runtime.raise(h4, c, CreatureLoaded(actor));
        runtime.raise(h4, c, PlayerEntered(EntityRef(7)));
    }
    assert(!room4.despawned.length && !room4.zoned.length);
    assert(room4.signals == [Signal(spawner, Aq40Signal.ouroGone, 0)], "his sand not woken for the next pull");
    // Both twins slain, the save after it lost: done.
    auto room5 = new FakeChambers;
    room5.killed = [npcVeklor, npcVeknilash];
    auto h5 = restoredFrom(room5, saved.data, [lor, nilash], waiting);
    assert(ask(room5, h5, Aq40Encounter.twins) == EncounterState.done);
}
