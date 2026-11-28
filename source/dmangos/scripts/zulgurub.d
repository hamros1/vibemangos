/**
 * Zul'Gurub (map 309): the copy's script (the high priests, Bloodlord Mandokir and Ohgan, the Zealots,
 * Arlokk's forcefield and her prowlers, Hakkar's power waning as each priest falls), the area triggers
 * where Hakkar speaks, the bosses High Priest Venoxis, High Priestess Jeklik and her bat riders, High
 * Priestess Mar'li, High Priest Thekal with Zealots Lor'Khan and Zath (who rise again unless all three
 * fall together), High Priestess Arlokk and the Zulian Prowlers, Bloodlord Mandokir and Ohgan, Renataki,
 * Hakkar, the Soulflayers, and the Gong of Bethekk. Most of their spells are their `creature_spell_list`s;
 * the scripts change lists with their phases.
 */
module dmangos.scripts.zulgurub;

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
enum ZgEncounter : ubyte
{
    jeklik,
    venoxis,
    marli,
    thekal,
    arlokk,
    ohgan,   /// Mandokir's; `special`: he comes down from his perch
    lorkhan,
    zath,
}

/// Creatures and objects of the copy.
enum : uint
{
    npcLorkhan = 11347,
    npcZath = 11348,
    npcThekal = 14509,
    npcJindo = 11380,
    npcHakkar = 14834,
    npcPantherTrigger = 15091,
    npcMandokir = 11382,
    npcMarli = 14510,
    npcArlokk = 14515,
    npcOhgan = 14988,
    npcChainedSpirit = 15117,
    npcZulianProwler = 15101,
    npcBatRider = 14750,
    npcFrenziedBat = 14965,
    npcSpawnOfMarli = 15041,
    npcShadeOfJindo = 14986,      /// Jin'do's: Delusions bring them, seen only by those it marks
    npcPowerfulHealingWard = 14987,
    npcBrainWashTotem = 15112,
    npcGrilek = 15082,     /// the Edge of Madness's four, the Brazier of Madness's (one a fortnight)
    npcHazzarah = 15083,
    npcRenataki = 15084,
    npcWushoolay = 15085,
    npcGahzranka = 15114,  /// the Mudskunk Lure's

    goGongOfBethekk = 180526,
    goForcefield = 180497,
}

/// What scripts of the copy say to each other, beyond the encounters' states (ids 0 .. 7).
enum ZgSignal : uint
{
    powerDown = 100,    /// the copy to Hakkar: a priest fell
    comeDown = 101,     /// the copy to Mandokir: his raptor's keepers are slain
    toAid = 102,        /// the copy to a prowler it summoned: to Arlokk's wall
    prowlers = 103,     /// Arlokk to the copy: her prowlers come (value 1) or stop (0)
    vanished = 104,     /// a spell script to Arlokk or Renataki: the vanish took hold (`value`: low guid bits of no use)
    preventRevive = 105, /// Thekal to a Zealot: all three are down at once; stay down
    revive = 106,       /// a resurrect spell script to its caster
    evade = 107,        /// Thekal to his Zealots: back home with me
    gratsJindo = 108,   /// Mandokir to the copy: Jin'do congratulates him
    ohganSlain = 109,   /// the copy to Mandokir: his raptor fell (a summon back from the checkpoint tells only it)
}

private static immutable float[3] mandokirDownstairs = [-12196.30f, -1948.37f, 130.31f];
private static immutable float[3] arlokkWallShield = [-11494.76f, -1627.56f, 41.30f];

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/**
 * What the copy remembers: its encounters (saved in `instance.data`). While Arlokk's fight is under way she and her
 * prowlers, summons, are kept in the copy's checkpoint (`setArlokk`): a worker's crash resumes her fight, and one saved
 * without her fails, so that her forcefield opens and the gong calls her again. Mandokir, his keepers slain, comes
 * down from his perch again as he comes back into the world there.
 */
@instance("instance_zulgurub")
struct ZulGurub
{
    enum int sayMinionDestroy = -1_309_022, sayHakkarProtect = -1_309_023;
    enum uint triggerEnter = 3958, triggerAltar = 3960;

    EncounterState[ZgEncounter.max + 1] encounters;
    bool introYelled, altarYelled;

    @transient EntityRef hakkar, mandokir, jindo, forcefield;
    @transient EntityRef[5] leftTriggers, rightTriggers;
    @transient ubyte lefts, rights;
    @transient bool prowling;
    @transient uint prowlersSent;
    @transient EntityRef arlokk;
    /// Her living prowlers while her fight is under way: saved in the checkpoint, not in this layout, each back in the
    /// list as it comes back into the world (`CreatureLoaded`).
    @transient EntityRef[] prowlers;
    @transient bool recoveringArlokk; /// her fight came back from its checkpoint: she fights the first player back

    /// A boss the raid calls with an item it spends (the Brazier of Madness, the Mudskunk Lure): a summon, kept in the
    /// copy's checkpoint while he lives, so a crash does not take him and the item with him.
    private static bool isCalledBoss(uint entry)
    {
        return (entry >= npcGrilek && entry <= npcWushoolay) || entry == npcGahzranka;
    }

    /// The summons of a boss's fight (spawns themselves, the bosses come back from their fight snapshots): kept in
    /// the copy's checkpoint while the fight is under way, so a crash brings them back with it. Mandokir's raptor and
    /// the chained spirits that revive the fallen, Jeklik's bat riders and bats, Mar'li's hatchlings.
    private static immutable ZgEncounter[uint] fightSummonOf;
    shared static this()
    {
        fightSummonOf = [npcOhgan: ZgEncounter.ohgan, npcChainedSpirit: ZgEncounter.ohgan,
            npcBatRider: ZgEncounter.jeklik, npcFrenziedBat: ZgEncounter.jeklik, npcSpawnOfMarli: ZgEncounter.marli];
    }

    /// Those summons, as they come into the world (back from the checkpoint too), till they die or their fight ends.
    @transient EntityRef[] fightSummons;
    /// Jin'do's shades and totems, kept the same way: his fight has no encounter state, so they are kept as they come
    /// and let go (sent away) as he dies or gives up his fight.
    @transient EntityRef[] jindoSummons;

    private static bool isJindoSummon(uint entry)
    {
        return entry == npcShadeOfJindo || entry == npcPowerfulHealingWard || entry == npcBrainWashTotem;
    }

    private void jindoOver(ref InstanceContext copy)
    {
        foreach (summon; jindoSummons)
        {
            copy.releaseCheckpointActor(summon);
            if (copy.alive(summon))
                copy.despawn(summon);
        }
        jindoSummons = null;
        copy.checkpoint();
    }

    private void keepFightSummons(ref InstanceContext copy, ZgEncounter which)
    {
        import std.algorithm.mutation : remove;

        const active = encounters[which] == EncounterState.inProgress;
        foreach_reverse (i, summon; fightSummons)
            if (fightSummonOf[summon.entry] == which)
            {
                if (active && copy.alive(summon))
                    copy.checkpointCreature(summon);
                else if (!active)
                {
                    copy.releaseCheckpointActor(summon);
                    // Mandokir's go with his fight, and Jeklik's bat riders (each sends hers away herself, but one
                    // back from a crash knows them no more).
                    if ((which == ZgEncounter.ohgan || summon.entry == npcBatRider) && copy.alive(summon))
                        copy.despawn(summon);
                    fightSummons = fightSummons.remove(i);
                }
            }
    }

    enum uint shadePassive = 24_307, randomAggro = 23_878, shadeVisual = 24_313;

    private bool arlokkActive() const
    {
        return encounters[ZgEncounter.arlokk] == EncounterState.inProgress;
    }

    enum Step : ubyte { prowlers }
    Schedule!Step steps;

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case npcHakkar:
            hakkar = e.creature;
            break;
        case npcMandokir:
            mandokir = e.creature;
            mandokirBack(copy);
            break;
        case npcArlokk:
            arlokk = e.creature;
            if (arlokkActive) // a clean handoff brings her in without a signal: she stays in the checkpoint
                copy.checkpointCreature(arlokk);
            break;
        case npcZulianProwler:
            import std.algorithm.searching : canFind;

            // Her prowlers as they come, and as a handoff or the checkpoint brings them back: kept with her fight.
            if (e.summoned && arlokkActive && !prowlers.canFind(e.creature))
            {
                prowlers ~= e.creature;
                copy.checkpointCreature(e.creature);
            }
            break;
        case npcJindo:
            jindo = e.creature;
            break;
        case npcOhgan, npcChainedSpirit, npcBatRider, npcFrenziedBat, npcSpawnOfMarli:
            import std.algorithm.searching : canFind;

            if (!e.summoned || fightSummons.canFind(e.creature))
                break;
            fightSummons ~= e.creature;
            if (encounters[fightSummonOf[e.creature.entry]] == EncounterState.inProgress)
                copy.checkpointCreature(e.creature);
            break;
        case npcShadeOfJindo, npcPowerfulHealingWard, npcBrainWashTotem:
            import std.algorithm.searching : canFind;

            if (!e.summoned || jindoSummons.canFind(e.creature))
                break;
            const fresh = !copy.hasSavedCreature(e.creature);
            jindoSummons ~= e.creature;
            copy.checkpointCreature(e.creature);
            // A shade as it comes (CMaNGOS's `SummonShadeOfJindo`): unseen but by those Delusions marks, after
            // whoever it finds, and its visual. One back from the checkpoint has them already.
            if (fresh && e.creature.entry == npcShadeOfJindo)
                foreach (spell; [shadePassive, randomAggro, shadeVisual])
                    copy.castSpell(e.creature, spell, e.creature);
            break;
        case npcGrilek, npcHazzarah, npcRenataki, npcWushoolay, npcGahzranka:
            if (e.summoned) // called, back from the checkpoint, or brought by a handoff: kept till slain
                copy.checkpointCreature(e.creature);
            break;
        case npcPantherTrigger:
            addTrigger(e.creature, where(copy, e.creature).y);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        if (e.object.entry == goForcefield)
        {
            forcefield = e.object;
            copy.door(e.object, encounters[ZgEncounter.arlokk] != EncounterState.inProgress);
        }
    }

    /**
     * Mandokir came into the world. His keepers slain (the Vilebranch Speaker's death says so) and he not yet slain,
     * one back on his perch, untouchable (after a crash, or the copy reloaded), comes down again: nothing else would
     * bring him to the raid.
     */
    private void mandokirBack(ref InstanceContext copy)
    {
        const state = encounters[ZgEncounter.ohgan];
        if (state != EncounterState.notStarted && state != EncounterState.done
            && (copy.unitFlagsOf(mandokir) & UnitFlag.immuneToPlayer) && !copy.alive(copy.victimOf(mandokir)))
            copy.signal(mandokir, ZgSignal.comeDown);
    }

    /// The panther triggers by Arlokk's altar, left and right of it.
    void addTrigger(EntityRef trigger, float y)
    {
        if (y < -1626)
        {
            if (lefts < leftTriggers.length)
                leftTriggers[lefts++] = trigger;
        }
        else if (rights < rightTriggers.length)
            rightTriggers[rights++] = trigger;
    }

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id <= ZgEncounter.max)
            copy.answer(encounters[e.id]);
    }

    /**
     * The copy came back from its save. Arlokk's fight under way resumes from its checkpoint when a player comes back;
     * one saved without her (an older save, or a crash before she came) failed: her forcefield opens, her prowlers stop
     * and the gong calls her again.
     */
    void on(ref InstanceContext copy, const ref Restored e)
    {
        foreach (entry; [npcGrilek, npcHazzarah, npcRenataki, npcWushoolay, npcGahzranka, npcOhgan, npcChainedSpirit,
                npcBatRider, npcFrenziedBat, npcSpawnOfMarli, npcShadeOfJindo, npcPowerfulHealingWard, npcBrainWashTotem])
            if (copy.hasSavedCreature(entry))
                copy.waitForPlayer(); // a called boss, or a fight's summons, come back with the first player
        if (!arlokkActive)
            return;
        if (copy.hasSavedCreature(npcArlokk))
        {
            recoveringArlokk = true;
            copy.waitForPlayer();
        }
        else
            setArlokk(copy, EncounterState.failed);
    }

    /// A player back in the copy (after a crash, say) during Arlokk's fight: she and her idle prowlers go after them.
    void on(ref InstanceContext copy, const ref PlayerEntered e)
    {
        if (!arlokkActive)
            return;
        if (recoveringArlokk)
        {
            recoveringArlokk = false;
            if (arlokk && copy.alive(arlokk) && !copy.alive(copy.victimOf(arlokk)))
                copy.attack(arlokk, e.player);
        }
        foreach (prowler; prowlers)
            if (copy.alive(prowler) && !copy.alive(copy.victimOf(prowler)))
                copy.attack(prowler, e.player);
    }

    /// Arlokk's checkpoint could not bring her back: her forcefield must not stay shut on the raid.
    void on(ref InstanceContext copy, const ref CreatureEvaded e)
    {
        if (e.creature.entry == npcArlokk && arlokkActive)
            setArlokk(copy, EncounterState.failed);
        if (e.creature.entry == npcJindo && jindoSummons.length)
            jindoOver(copy); // he gave up his fight: his shades and totems go
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        {
            import std.algorithm.mutation : remove;
            import std.algorithm.searching : countUntil;

            const kept = fightSummons.countUntil(e.creature);
            if (kept >= 0)
            {
                fightSummons = fightSummons.remove(kept);
                copy.releaseCheckpointActor(e.creature); // slain, it stays slain
                if (e.creature.entry == npcOhgan && mandokir && copy.alive(mandokir))
                    copy.signal(mandokir, ZgSignal.ohganSlain);
                return;
            }
        }
        if (e.creature.entry == npcJindo)
            return jindoOver(copy);
        if (isJindoSummon(e.creature.entry))
        {
            import std.algorithm.mutation : remove;
            import std.algorithm.searching : countUntil;

            const kept = jindoSummons.countUntil(e.creature);
            if (kept >= 0)
            {
                jindoSummons = jindoSummons.remove(kept);
                copy.releaseCheckpointActor(e.creature); // slain, it stays slain
            }
            return;
        }
        if (isCalledBoss(e.creature.entry))
        {
            copy.releaseCheckpointActor(e.creature); // slain, he stays slain
            copy.checkpoint();
            return;
        }
        const slain = prowlers.countUntil(e.creature);
        if (slain >= 0)
        {
            prowlers = prowlers.remove(slain);
            copy.releaseCheckpointActor(e.creature); // a prowler slain stays slain
        }
    }

    /**
     * Arlokk's encounter in `state`: her forcefield shut while it is under way, and she and her prowlers saved with the
     * copy; a wipe or her death opens it, stops her prowlers and lets them go. Her death weakens Hakkar.
     */
    private void setArlokk(ref InstanceContext copy, EncounterState state)
    {
        encounters[ZgEncounter.arlokk] = state;
        if (forcefield)
            copy.door(forcefield, !arlokkActive);
        if (state == EncounterState.done && hakkar && copy.alive(hakkar))
            copy.signal(hakkar, ZgSignal.powerDown);
        if (arlokkActive)
        {
            if (arlokk && copy.alive(arlokk))
                copy.checkpointCreature(arlokk);
        }
        else
        {
            prowling = false;
            recoveringArlokk = false;
            steps.cancel(Step.prowlers);
            if (arlokk)
                copy.releaseCheckpointActor(arlokk);
            foreach (prowler; prowlers)
                copy.releaseCheckpointActor(prowler);
            prowlers = null;
        }
        copy.checkpoint();
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id == ZgSignal.prowlers)
        {
            prowling = e.value != 0;
            if (prowling)
                steps.every(Step.prowlers, 0.msecs, 8.seconds);
            else
                steps.cancel(Step.prowlers);
            return;
        }
        if (e.id > ZgYell.base)
            return yellAt(copy, e.id - ZgYell.base);
        if (e.id == ZgSignal.gratsJindo)
        {
            if (jindo && copy.alive(jindo))
                copy.say(jindo, Mandokir.sayGratsJindo);
            return;
        }
        if (e.id > ZgEncounter.max)
            return;
        const which = cast(ZgEncounter) e.id;
        const state = cast(EncounterState) e.value;
        if (which == ZgEncounter.arlokk)
        {
            if (e.from.isCreature && e.from.entry == npcArlokk)
                arlokk = e.from;
            return setArlokk(copy, state);
        }
        encounters[which] = state;
        if (which == ZgEncounter.ohgan || which == ZgEncounter.jeklik || which == ZgEncounter.marli)
        {
            keepFightSummons(copy, which);
            copy.checkpoint();
        }
        final switch (which)
        {
        case ZgEncounter.jeklik, ZgEncounter.venoxis, ZgEncounter.thekal, ZgEncounter.marli:
            if (state == EncounterState.done && hakkar && copy.alive(hakkar))
                copy.signal(hakkar, ZgSignal.powerDown);
            break;
        case ZgEncounter.arlokk: // `setArlokk`
            break;
        case ZgEncounter.ohgan:
            if (state != EncounterState.special)
                break;
            // His keepers slain (the Speaker's death, already on its way to the database): saved with it, or a crash
            // could keep the death and lose what it means, and nothing would bring him down.
            copy.checkpoint();
            if (mandokir)
                copy.signal(mandokir, ZgSignal.comeDown);
            break;
        case ZgEncounter.lorkhan, ZgEncounter.zath:
            break;
        }
    }

    void on(ref InstanceContext copy, Step step)
    {
        // A prowler from a trigger on each side, to Arlokk's aid (forty at most).
        foreach (side; [leftTriggers[0 .. lefts], rightTriggers[0 .. rights]])
        {
            if (side.length == 0)
                continue;
            const from = side[(prowlersSent++) % side.length];
            const prowler = copy.summon(npcZulianProwler, where(copy, from), 0);
            if (prowler)
                copy.signal(prowler, ZgSignal.toAid, cast(int) from.guid);
        }
    }

    /// Hakkar speaks to those entering, and to those reaching his altar.
    void yellAt(ref InstanceContext copy, uint trigger)
    {
        if (trigger == triggerEnter && !introYelled)
        {
            introYelled = true;
            if (hakkar)
                copy.say(hakkar, sayHakkarProtect);
        }
        else if (trigger == triggerAltar && !altarYelled)
        {
            altarYelled = true;
            if (hakkar)
                copy.say(hakkar, sayMinionDestroy);
        }
    }
}

/// A Zul'Gurub area trigger where Hakkar speaks (once a copy).
@areaTrigger("at_zulgurub")
struct AtZulGurub
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (e.trigger == ZulGurub.triggerEnter || e.trigger == ZulGurub.triggerAltar)
            at.signalDungeon(ZgYell.base + e.trigger);
    }
}

/// Signals of the area trigger: Hakkar's yell at trigger `id - base`.
enum ZgYell : uint { base = 1000 }

/**
 * High Priest Venoxis: a priest of Hethiss (spell list one), a snake below half health (list two, his
 * threat forgotten, a poison cloud), and fiercer still below a quarter; frenzied below a fifth.
 */
@creature("boss_venoxis")
struct Venoxis
{
    enum int sayTransform = -1_309_000, sayDeath = -1_309_001;
    enum : uint { snakeForm = 23849, frenzy = 23537, virulentPoisonProc = 22413, poisonCloud = 23861 }
    enum : uint { listPhase1 = 1450701, listPhase2 = 1450702, listPhase3 = 1450703 }
    ubyte phase;
    bool frenzied;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.spellList(listPhase1);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        phase = 0;
        frenzied = false;
        me.spellList(listPhase1);
        me.signalDungeon(ZgEncounter.venoxis, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(ZgEncounter.venoxis, EncounterState.inProgress);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (phase == 0 && e.after <= 50 && me.castSelf(snakeForm) == ActionResult.ok)
        {
            phase = 1;
            me.say(sayTransform);
            me.castSelf(poisonCloud);
            if (!me.hasAura(me.self, virulentPoisonProc))
                me.castSelf(virulentPoisonProc, true);
            me.resetThreat();
            me.spellList(listPhase2);
        }
        if (phase == 1 && e.after < 25)
        {
            phase = 2;
            me.spellList(listPhase3);
        }
        if (!frenzied && e.after < 20 && me.castSelf(frenzy) == ActionResult.ok)
            frenzied = true;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        me.say(sayDeath);
        me.signalDungeon(ZgEncounter.venoxis, EncounterState.done);
    }
}

/**
 * High Priestess Jeklik: takes to the air as a bat when attacked (list one), lands at half health in
 * her troll form (list two, her threat forgotten), and at 35% calls bat riders who rain liquid fire.
 */
@creature("boss_jeklik")
struct Jeklik
{
    enum : int
    {
        sayAggro = -1_309_002,
        sayRainFire = -1_309_003,
        sayDeath = -1_309_004,
    }
    enum : uint { greenChanneling = 13540, batForm = 23966, transformVisual = 24085, liquidFire = 23968 }
    enum : uint { listPhase1 = 1451701, listPhase2 = 1451702 }
    static immutable flyTo = Location(-12281.58f, -1392.84f, 146.1f);
    static immutable Location[2] ridersAt = [
        Location(-12298.03f, -1368.506f, 145.3976f, 4.799655f),
        Location(-12301.69f, -1371.292f, 145.0924f, 4.747295f),
    ];

    enum Step : ubyte { delayedRider }
    Schedule!Step steps;
    bool landed, ridersCalled;
    EntityRef[2] riders;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        rest(me);
    }

    private void rest(ref CreatureContext me)
    {
        steps.clear();
        landed = ridersCalled = false;
        me.spellList(listPhase1);
        me.castSelf(greenChanneling);
        me.combatMovement(false);
        me.flying(false);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.signalDungeon(ZgEncounter.jeklik, EncounterState.inProgress);
        if (me.castSelf(batForm) == ActionResult.ok)
        {
            me.flying(true);
            me.moveNow(flyTo, 1);
        }
        else
            me.combatMovement(true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == 1 && me.inCombat)
        {
            me.combatMovement(true);
            if (const victim = me.selectTarget(Pick.topThreat))
                me.attack(victim);
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!landed && e.after < 50 && me.castSelf(transformVisual) == ActionResult.ok)
        {
            landed = true;
            me.removeAura(me.self, batForm);
            me.flying(false);
            me.resetThreat();
            me.spellList(listPhase2);
        }
        if (!ridersCalled && e.after < 35)
        {
            ridersCalled = true;
            riders[0] = me.summon(npcBatRider, ridersAt[0]);
            riders[1] = me.summon(npcBatRider, ridersAt[1]);
            if (riders[1])
                me.signal(riders[1], ZgSignal.toAid);
            steps.after(Step.delayedRider, 15.seconds);
            me.say(sayRainFire);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (riders[0])
            me.signal(riders[0], ZgSignal.toAid);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        despawnRiders(me);
        me.flying(false);
        me.teleport(me.location); // straight home from the air, as she evades
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        rest(me);
        me.signalDungeon(ZgEncounter.jeklik, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        me.say(sayDeath);
        despawnRiders(me);
        me.signalDungeon(ZgEncounter.jeklik, EncounterState.done);
    }

    private void despawnRiders(ref CreatureContext me)
    {
        foreach (ref r; riders)
            if (r)
            {
                me.despawn(r);
                r = EntityRef.init;
            }
    }
}

/// A Gurubashi Bat Rider: one of Jeklik's raining liquid fire (passive, flying over), or one met on
/// the way, who shouts as it fights and drinks its unstable concoction when hurt.
@creature("npc_gurubashi_bat_rider")
struct GurubashiBatRider
{
    enum int saySelfDetonate = -1_309_028;
    enum : uint { thrash = 8876, demoralizingShout = 23511, unstableConcoction = 24024, liquidFire = 23968 }
    bool bomber, concocted;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != ZgSignal.toAid)
            return;
        // Jeklik's: it flies over the fight, raining fire, and is no one's to fight.
        bomber = true;
        me.reactState(Reaction.passive);
        me.flying(true);
        me.unitFlags(UnitFlag.uninteractible, true);
        me.castSelf(liquidFire, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (bomber)
            return;
        me.castSelf(demoralizingShout);
        me.unitFlags(UnitFlag.uninteractible, false);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!concocted && e.after < 40 && me.castSelf(unstableConcoction) == ActionResult.ok)
        {
            concocted = true;
            me.say(saySelfDetonate);
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        concocted = false;
        if (!me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
    }
}

/// High Priestess Mar'li: every minute between her troll form (list one) and her spider form (list two,
/// her threat forgotten, a charge at someone).
@creature("boss_marli")
struct Marli
{
    enum : int
    {
        sayAggro = -1_309_005,
        sayTransform = -1_309_006,
        sayTransformBack = -1_309_025,
        sayDeath = -1_309_008,
    }
    enum : uint { charge = 22911, spiderForm = 24084, transformBack = 24085, hatchEggs = 24083 }
    enum : uint { listPhase1 = 1451001, listPhase2 = 1451002 }
    enum Step : ubyte { phaseChange, charge }
    Schedule!Step steps;
    bool spider;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.spellList(listPhase1);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.castSelf(hatchEggs);
        me.signalDungeon(ZgEncounter.marli, EncounterState.inProgress);
        steps.after(Step.phaseChange, 60.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.phaseChange:
            if (!spider && me.castSelf(spiderForm) == ActionResult.ok)
            {
                me.say(sayTransform);
                me.resetThreat();
                me.spellList(listPhase2);
                spider = true;
                steps.after(Step.charge, 1.seconds);
                steps.after(step, 60.seconds);
            }
            else if (spider && me.castSelf(transformBack) == ActionResult.ok)
            {
                me.say(sayTransformBack);
                me.removeAura(me.self, spiderForm);
                me.spellList(listPhase1);
                spider = false;
                steps.after(step, 60.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.charge:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            if (!target || me.castSpell(charge, target) != ActionResult.ok)
                steps.after(step, retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        spider = false;
        me.spellList(listPhase1);
        me.signalDungeon(ZgEncounter.marli, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
        me.signalDungeon(ZgEncounter.marli, EncounterState.done);
    }
}

/**
 * What High Priest Thekal and his Zealots share: none of them dies of his wounds. Each falls as if dead,
 * and after ten seconds rises again, unless the other two are down too: then Thekal rises as a tiger
 * (and dies for good the next time), and the Zealots stay down.
 */
private mixin template FakeDeath(ZgEncounter which)
{
    enum uint pacifySelf = 19951, resurrect = 24173;

    /// Down, as if dead.
    private void fall(ref CreatureContext me)
    {
        me.interrupt();
        me.unitFlags(UnitFlag.uninteractible, true);
        me.standState(StandState.dead);
        me.castSelf(pacifySelf, true);
        me.combatMovement(false);
        me.melee(false);
        down = true;
        me.signalDungeon(which, EncounterState.special);
    }

    /// Up again (only its look, with `onlyLook`).
    private void rise(ref CreatureContext me, bool onlyLook = false)
    {
        me.unitFlags(UnitFlag.uninteractible, false);
        me.standState(StandState.stand);
        me.removeAura(me.self, pacifySelf);
        down = false;
        if (onlyLook)
            return;
        me.setHealthPercent(100);
        me.resetThreat();
        me.combatMovement(true);
        me.melee(true);
        me.deathPrevention(true);
        if (const victim = me.selectTarget(Pick.topThreat))
            me.attack(victim);
    }

    /// Whether the other two are down too (as the copy knows).
    private bool othersDown(ref CreatureContext me, ZgEncounter a, ZgEncounter b)
    {
        return me.askDungeon(a) == EncounterState.special && me.askDungeon(b) == EncounterState.special;
    }
}

/// High Priest Thekal: spell list one; down (not dead) he rises in ten seconds, or as a tiger (list two)
/// if his Zealots are down with him; the tiger enrages below 11%.
@creature("boss_thekal")
struct Thekal
{
    enum int sayAggro = -1_309_009, sayDeath = -1_309_010;
    enum uint diesEmote = 10453; /// broadcast text
    enum : uint { tigerForm = 24169, enrage = 8269, resurrectVisual = 24171 }
    enum : uint { listPhase1 = 1450901, listPhase2 = 1450902 }
    enum Step : ubyte { resurrect, tiger }
    Schedule!Step steps;
    bool down, tiger, enraged;

    mixin FakeDeath!(ZgEncounter.thekal);

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
        me.spellList(listPhase1);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.signalDungeon(ZgEncounter.thekal, EncounterState.inProgress);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!tiger && !down && e.after == 0)
        {
            fall(me);
            steps.after(Step.resurrect, 10.seconds);
            if (preventAddsRising(me))
                steps.after(Step.resurrect, 1.seconds);
        }
        if (tiger && !enraged && e.after < 11 && me.castSelf(enrage) == ActionResult.ok)
            enraged = true;
    }

    /// His Zealots are down with him: they stay down, and he rises as the tiger.
    private bool preventAddsRising(ref CreatureContext me)
    {
        if (!othersDown(me, ZgEncounter.zath, ZgEncounter.lorkhan))
            return false;
        EntityRef[1] z;
        if (me.creaturesNearby(npcZath, 150, z[]))
            me.signal(z[0], ZgSignal.preventRevive);
        if (me.creaturesNearby(npcLorkhan, 150, z[]))
            me.signal(z[0], ZgSignal.preventRevive);
        return true;
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.resurrect:
            me.castSelf(resurrect, true);
            me.signalDungeon(ZgEncounter.thekal, EncounterState.inProgress);
            if (preventAddsRising(me))
            {
                // The tiger's turn.
                rise(me, true);
                me.unitFlags(UnitFlag.uninteractible, true);
                me.melee(false);
                me.castSelf(resurrectVisual);
                steps.after(Step.tiger, 5.seconds);
            }
            else
                rise(me);
            break;
        case Step.tiger:
            me.castSelf(tigerForm);
            tiger = true;
            me.setHealthPercent(100);
            me.deathPrevention(false);
            me.melee(true);
            me.combatMovement(true);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.spellList(listPhase2);
            if (const victim = me.selectTarget(Pick.topThreat))
                me.attack(victim);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        EntityRef[1] z;
        foreach (entry; [npcZath, npcLorkhan])
            if (me.creaturesNearby(entry, 150, z[]))
                me.signal(z[0], ZgSignal.evade);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (down)
            rise(me, true);
        tiger = enraged = false;
        me.deathPrevention(true);
        me.combatMovement(true);
        me.melee(true);
        me.removeAura(me.self, tigerForm);
        me.spellList(listPhase1);
        me.signalDungeon(ZgEncounter.thekal, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
        me.signalDungeon(ZgEncounter.thekal, EncounterState.done);
        EntityRef[1] z;
        foreach (entry; [npcZath, npcLorkhan])
            if (me.creaturesNearby(entry, 150, z[]))
            {
                me.sayAs(z[0], diesEmote);
                me.despawn(z[0], 1000);
            }
    }
}

/// Zealot Lor'Khan and Zealot Zath, at Thekal's side: down (not dead) each rises in ten seconds, unless
/// Thekal and the other are down too.
@creature("mob_zealot_lorkhan", "mob_zealot_zath")
struct Zealot
{
    enum Step : ubyte { resurrect }
    Schedule!Step steps;
    bool down, stayDown;
    ZgEncounter which = ZgEncounter.lorkhan;

    mixin FakeDeath!(ZgEncounter.lorkhan) deathOfLorkhan;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        which = me.self.entry == npcZath ? ZgEncounter.zath : ZgEncounter.lorkhan;
        me.deathPrevention(true);
        me.signalDungeon(which, EncounterState.notStarted);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(which, EncounterState.inProgress);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (down || e.after != 0)
            return;
        // Down, as its fellows: the copy knows which of them it is.
        me.interrupt();
        me.unitFlags(UnitFlag.uninteractible, true);
        me.standState(StandState.dead);
        me.castSelf(deathOfLorkhan.pacifySelf, true);
        me.combatMovement(false);
        me.melee(false);
        down = true;
        me.signalDungeon(which, EncounterState.special);
        steps.after(Step.resurrect, 10.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == ZgSignal.preventRevive)
        {
            stayDown = true;
            steps.clear();
            me.interrupt();
        }
        else if (e.id == ZgSignal.evade)
            me.evade();
    }

    void on(ref CreatureContext me, Step step)
    {
        const other = which == ZgEncounter.zath ? ZgEncounter.lorkhan : ZgEncounter.zath;
        if (stayDown || (me.askDungeon(ZgEncounter.thekal) == EncounterState.special
                && me.askDungeon(other) == EncounterState.special))
            return;
        me.castSelf(deathOfLorkhan.resurrect, true);
        me.signalDungeon(which, EncounterState.inProgress);
        deathOfLorkhan.rise(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (down)
            deathOfLorkhan.rise(me, true);
        stayDown = false;
        me.deathPrevention(true);
        me.combatMovement(true);
        me.melee(true);
        me.signalDungeon(which, EncounterState.notStarted);
    }
}

/// High Priestess Arlokk: her forcefield closes as she fights; prowlers come from both sides; every so
/// often she turns panther (list two, her threat forgotten) or back (list one); she vanishes and strikes
/// from hiding.
@creature("boss_arlokk")
struct Arlokk
{
    enum : int { sayAggro = -1_309_011, sayFeastPanther = -1_309_012, sayDeath = -1_309_013 }
    enum : uint { pantherTransform = 24190, hateToZero = 20538, transformVisual = 24085, superInvis = 24235 }
    enum : uint { listPhase1 = 1451501, listPhase2 = 1451502 }
    enum Step : ubyte { transition, invisSelect, invisEnd }
    Schedule!Step steps;
    bool panther;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.spellList(listPhase1);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.signalDungeon(ZgEncounter.arlokk, EncounterState.inProgress);
        me.signalDungeon(ZgSignal.prowlers, 1);
        steps.after(Step.transition, 30.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != ZgSignal.vanished)
            return;
        // Hidden: she forgets everyone, then picks her prey.
        me.resetThreat();
        me.melee(false);
        me.unitFlags(UnitFlag.uninteractible, true);
        steps.after(Step.invisSelect, 10.seconds);
        steps.after(Step.invisEnd, 50.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.transition:
            if (panther && me.castSelf(transformVisual) == ActionResult.ok)
            {
                me.removeAura(me.self, pantherTransform);
                panther = false;
                me.spellList(listPhase1);
                steps.after(step, 30.seconds);
            }
            else if (!panther && me.castSelf(pantherTransform) == ActionResult.ok)
            {
                me.castSelf(hateToZero);
                panther = true;
                me.spellList(listPhase2);
                steps.after(step, 120.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.invisSelect:
            if (const prey = me.selectTarget(Pick.random, PickFilter.player))
            {
                me.teleport(where(me, prey));
                me.attack(prey);
            }
            me.removeAura(me.self, superInvis);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.melee(true);
            break;
        case Step.invisEnd:
            me.removeAura(me.self, superInvis);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.melee(true);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        panther = false;
        me.unitFlags(UnitFlag.uninteractible, false);
        me.melee(true);
        me.spellList(listPhase1);
        me.signalDungeon(ZgEncounter.arlokk, EncounterState.failed);
        me.signalDungeon(ZgSignal.prowlers, 0);
        me.despawn(); // summoned by the gong: gone until it is struck again
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
        me.signalDungeon(ZgSignal.prowlers, 0);
        me.signalDungeon(ZgEncounter.arlokk, EncounterState.done);
    }
}

/// `spell_arlokk_vanish`, `spell_renataki_vanish`: the vanish took hold; its caster's script hides it.
/// Delusions of Jin'do (24306): on its player, Jin'do calls a Shade of Jin'do (24308), whom only those it marks see
/// (CMaNGOS's `DelusionsOfJindo`).
@spell("spell_delusions_of_jindo")
struct DelusionsOfJindo
{
    enum uint summonShade = 24_308;

    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (e.effect == 0 && e.caster.isCreature)
            it.castSpell(e.caster, summonShade, e.caster, true);
    }
}

@spell("spell_arlokk_vanish", "spell_renataki_vanish")
struct ZgVanish
{
    void on(ref SpellContext spell, const ref EffectHit e)
    {
        if (e.caster.isCreature)
            spell.signal(e.caster, ZgSignal.vanished, cast(int)(e.target.guid & 0x7FFF_FFFF));
    }
}

/// `spell_thekal_resurrect`: its caster rises (the scripts raise themselves with the cast; nothing else).
@spell("spell_thekal_resurrect")
struct ThekalResurrect
{
    void on(ref SpellContext spell, const ref EffectHit e)
    {
        spell.consume();
    }
}

/// A Zulian Prowler: one Arlokk calls slinks to her wall and joins the fight; one of the jungle just sneaks.
@creature("npc_zulian_prowler")
struct ZulianProwler
{
    enum uint sneak = 22766;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(sneak);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != ZgSignal.toAid)
            return;
        EntityRef[41] others;
        if (me.creaturesNearby(npcZulianProwler, 200, others[]) > 40)
            return me.despawn();
        me.moveTo(Location(arlokkWallShield[0], arlokkWallShield[1], arlokkWallShield[2]), 1, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == 1)
            me.zoneCombat();
    }
}

/**
 * Bloodlord Mandokir: watches from his perch until the copy says his keepers are slain, then comes down
 * to fight; Ohgan fights with him (enraging him when slain), chained spirits revive the fallen, and
 * every third player he kills makes him stronger. His Threatening Gaze (his spell list casts it) he
 * announces to its player; whoever gains threat on him while it lasts is charged when it ends.
 */
@creature("boss_mandokir")
struct Mandokir
{
    enum : int
    {
        sayAggro = -1_309_015,
        sayDingKill = -1_309_016,
        sayGratsJindo = -1_309_017,
        emoteRage = -1_309_024,
        sayWatch = -1_309_018,
        sayWatchWhisper = -1_309_019,
    }
    enum : uint { enrage = 23537, levelUp = 24312, revive = 24341, threateningGaze = 24314, chargeGaze = 24315 }
    static immutable Location[19] spirits = [
        Location(-12150.9f, -1956.24f, 133.407f, 2.57835f), Location(-12157.1f, -1972.78f, 133.947f, 2.64903f),
        Location(-12172.3f, -1982.63f, 134.061f, 1.48664f), Location(-12194.0f, -1979.54f, 132.194f, 1.45916f),
        Location(-12211.3f, -1978.49f, 133.580f, 1.35705f), Location(-12228.4f, -1977.10f, 132.728f, 1.25495f),
        Location(-12250.0f, -1964.78f, 135.066f, 0.92901f), Location(-12264.0f, -1953.08f, 134.072f, 0.62663f),
        Location(-12289.0f, -1924.00f, 132.620f, 5.37829f), Location(-12267.3f, -1902.26f, 131.328f, 5.32724f),
        Location(-12255.3f, -1893.53f, 134.026f, 5.06413f), Location(-12229.9f, -1891.39f, 134.704f, 4.40047f),
        Location(-12215.9f, -1889.09f, 137.273f, 4.70285f), Location(-12200.5f, -1890.69f, 135.777f, 4.84422f),
        Location(-12186.0f, -1890.12f, 134.261f, 4.36513f), Location(-12246.3f, -1890.09f, 135.475f, 4.73427f),
        Location(-12170.7f, -1894.85f, 133.852f, 3.51690f), Location(-12279.0f, -1931.92f, 136.130f, 0.04151f),
        Location(-12266.1f, -1940.72f, 132.606f, 0.70910f),
    ];

    enum Step : ubyte { gaze }
    Schedule!Step steps;
    ubyte kills;
    EntityRef ohgan;
    EntityRef[19] chained;
    EntityRef watched;  /// the player under his gaze
    float watchedThreat; /// their threat on him when it fell on them

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == ZgSignal.comeDown)
            me.moveTo(Location(mandokirDownstairs[0], mandokirDownstairs[1], mandokirDownstairs[2]), 1, true);
        else if (e.id == ZgSignal.ohganSlain)
            ohganFell(me);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point != 1)
            return;
        me.unitFlags(UnitFlag.immuneToPlayer, false);
        me.zoneCombat();
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        foreach (i, at; spirits)
            chained[i] = me.summon(npcChainedSpirit, at);
        ohgan = me.summon(npcOhgan, Location.init, 0, me.victim);
        me.signalDungeon(ZgEncounter.ohgan, EncounterState.inProgress);
        steps.every(Step.gaze, 500.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.gaze:
            watch(me);
            break;
        }
    }

    /// Ohgan slain: his master rages. (Told by his death: summoned to go when dead, he is gone from the map at
    /// once, and `alive` of a creature not here says yes. One back from the copy's checkpoint after a crash has
    /// no summoner to tell: the copy tells him then, `ZgSignal.ohganSlain`.)
    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (!e.gone && e.summoned == ohgan)
            ohganFell(me);
    }

    private void ohganFell(ref CreatureContext me)
    {
        if (me.hasAura(me.self, enrage))
            return; // told twice (his summoner's word and the copy's)
        ohgan = EntityRef.init;
        me.castSelf(enrage, true);
        me.say(emoteRage);
    }

    /// His gaze: who it falls on is told and watched; it over, the one who gained threat on him meanwhile is charged.
    private void watch(ref CreatureContext me)
    {
        if (watched)
        {
            if (me.hasAura(watched, threateningGaze))
                return;
            if (me.alive(watched) && me.threatOf(watched) > watchedThreat)
                me.castSpell(chargeGaze, watched, true);
            watched = EntityRef.init;
        }
        EntityRef[40] foes;
        foreach (foe; foes[0 .. me.threatList(foes[])])
            if (foe.isPlayer && me.hasAura(foe, threateningGaze))
            {
                watched = foe;
                watchedThreat = me.threatOf(foe);
                me.say(sayWatch, foe);
                me.say(sayWatchWhisper, foe);
                break;
            }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (!e.victim.isPlayer)
            return;
        if (++kills == 3)
        {
            me.say(sayDingKill);
            me.signalDungeon(ZgSignal.gratsJindo);
            me.castSelf(levelUp, true);
            kills = 0;
        }
        reviveFallen(me, e.victim);
    }

    /// The chained spirit nearest the fallen player brings it back. (Found about him: all of them are his, and one
    /// back from the copy's checkpoint after a crash is not among those he remembers summoning.)
    private void reviveFallen(ref CreatureContext me, EntityRef player)
    {
        EntityRef best;
        float nearest = 50;
        const at = where(me, player);
        EntityRef[spirits.length] near;
        foreach (s; near[0 .. me.creaturesNearby(npcChainedSpirit, 150, near[])])
            if (s && me.alive(s))
            {
                const there = where(me, s);
                const d = (there.x - at.x) ^^ 2 + (there.y - at.y) ^^ 2;
                if (d < nearest * nearest)
                {
                    nearest = d ^^ 0.5f;
                    best = s;
                }
            }
        if (best)
            me.castAs(best, revive, player);
    }

    private void unchain(ref CreatureContext me)
    {
        foreach (ref s; chained)
            if (s)
            {
                me.despawn(s);
                s = EntityRef.init;
            }
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
        me.signalDungeon(ZgEncounter.ohgan, EncounterState.failed);
        unchain(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        kills = 0;
        watched = EntityRef.init;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(ZgEncounter.ohgan, EncounterState.done);
        unchain(me);
    }
}

/// Ohgan, Mandokir's raptor: sunders armor; players he kills are revived by the chained spirits too.
@creature("mob_ohgan")
struct Ohgan
{
    enum uint sunderArmor = 24317;
    enum Step : ubyte { sunder }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.sunder, 5.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        steps.after(step, me.castSpell(sunderArmor) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (!e.victim.isPlayer)
            return;
        EntityRef[1] spirit;
        if (me.creaturesNearby(npcChainedSpirit, 50, spirit[]))
            me.castAs(spirit[0], Mandokir.revive, e.victim);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// Renataki: his spell list; vanished, he hides a moment and strikes from behind his prey.
@creature("boss_renataki")
struct Renataki
{
    enum : uint { thrash = 3391, spiritParticles = 18951, redLightning = 24240 }
    enum Step : ubyte { reappear }
    Schedule!Step steps;
    EntityRef prey;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(spiritParticles);
        me.castSelf(redLightning);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != ZgSignal.vanished)
            return;
        me.melee(false);
        me.combatMovement(false);
        prey = me.selectTarget(Pick.random, PickFilter.player);
        steps.after(Step.reappear, 5.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (prey && me.alive(prey))
        {
            me.teleport(where(me, prey));
            me.attack(prey);
            me.castSelf(thrash, true);
        }
        me.melee(true);
        me.combatMovement(true);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.melee(true);
        me.combatMovement(true);
    }
}

/// Hakkar the Soulflayer: as strong as the high priests still living (a stack of Hakkar's Power each);
/// his spell list does the rest.
@creature("boss_hakkar")
struct Hakkar
{
    enum int sayAggro = -1_309_020;
    enum : uint { doubleAttack = 19818, hakkarsPower = 24692 }

    void on(ref CreatureContext me, const ref Spawned e)
    {
        empower(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        empower(me);
    }

    /// A stack of his power for each priest alive.
    private void empower(ref CreatureContext me)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
        me.removeAura(me.self, hakkarsPower);
        foreach (priest; ZgEncounter.jeklik .. ZgEncounter.ohgan)
            if (me.askDungeon(priest) != EncounterState.done)
                me.castSelf(hakkarsPower, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == ZgSignal.powerDown)
            empower(me);
    }
}

/// A Soulflayer: Soul Tap, Lightning Breath, and one of fear or knockdown; one of enrage, frenzy (when
/// hurt) or thrash.
@creature("npc_soulflayer")
struct Soulflayer
{
    enum : uint { soulTap = 24619, lightningBreath = 20543, thrash = 8876, knockdown = 20276, fear = 22678,
        frenzy = 28371, enrage = 8269 }
    enum Step : ubyte { soulTap, breath, cc }
    Schedule!Step steps;
    uint ccSpell, buffSpell;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        ccSpell = me.random(2) ? fear : knockdown;
        static immutable uint[3] buffs = [enrage, frenzy, thrash];
        buffSpell = buffs[me.random(3)];
        if (buffSpell == thrash && !me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const cc = between(me, 2000, 5000);
        steps.after(Step.cc, cc);
        steps.after(Step.soulTap, between(me, cast(uint) cc.total!"msecs", 7000));
        steps.after(Step.breath, between(me, 7000, 9000));
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.casting)
            return cast(void) steps.after(step, retry);
        final switch (step)
        {
        case Step.soulTap:
            const target = me.selectTarget(Pick.random);
            steps.after(step, target && me.castSpell(soulTap, target) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.breath:
            steps.after(step, me.castSpell(lightningBreath) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.cc:
            steps.after(step, me.castSpell(ccSpell) == ActionResult.ok ? between(me, 8000, 10_000) : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (buffSpell != thrash && e.after <= 30 && !me.hasAura(me.self, buffSpell))
            me.castSelf(buffSpell);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (buffSpell == thrash && !me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
    }
}

/// The Gong of Bethekk: struck, it summons Arlokk (its own event does) unless she fights or has fallen.
@gameObject("go_gong_of_bethekk")
struct GongOfBethekk
{
    void on(ref GameObjectContext gong, const ref ObjectUsed e)
    {
        const state = gong.askDungeon(ZgEncounter.arlokk);
        if (state == EncounterState.done || state == EncounterState.inProgress)
            return gong.consume();
        gong.signalDungeon(ZgEncounter.arlokk, EncounterState.inProgress);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptKind, ScriptRuntime;

    /// A priest as its script sees it; the copy's states answer its questions.
    class FakePriest : BlackHole!CreatureHost
    {
        uint[] casts, lists;
        Signal[] dungeon, signals;
        EncounterState[8] states;
        uint flags, health = 100;
        bool preventing, swings = true;
        StandState stand;

        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(npcThekal) << 24)); }
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override void hostSignalDungeon(uint id, int value)
        {
            dungeon ~= Signal(EntityRef.init, id, value);
            if (id <= ZgEncounter.max)
                states[id] = cast(EncounterState) value;
        }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override int hostAskDungeon(uint id) { return id < states.length ? states[id] : 0; }
        override void hostSpellList(uint id) { lists ~= id; }
        override void hostUnitFlags(uint f, bool set) { flags = set ? flags | f : flags & ~f; }
        override void hostDeathPrevention(bool on) { preventing = on; }
        override void hostStandState(StandState s) { stand = s; }
        override void hostSetHealthPercent(EntityRef, uint p) { health = p; }
        override void hostMelee(bool on) { swings = on; }
        override size_t hostCreaturesNearby(uint entry, float, EntityRef[] into)
        {
            if (into.length == 0 || (entry != npcZath && entry != npcLorkhan))
                return 0;
            into[0] = EntityRef(0xF130_0000_0000_0002UL | (ulong(entry) << 24));
            return 1;
        }
    }
}

/// Thekal and his Zealots: Thekal falls alone and rises in ten seconds; when all three are down he
/// rises as the tiger (list two), the Zealots told to stay down, and the tiger dies for good.
unittest
{
    import std.algorithm.searching : canFind;

    alias self = dmangos.scripts.zulgurub;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakePriest;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_thekal");
    void run(int ms)
    {
        foreach (_; 0 .. ms / 100)
            runtime.tick(h, me, 100);
    }

    runtime.raise(h, me, Spawned());
    assert(host.preventing && host.lists == [Thekal.listPhase1]);
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.raise(h, me, Damaged(EntityRef(7), 5000, 3, 0));
    assert(host.stand == StandState.dead && (host.flags & UnitFlag.uninteractible));
    assert(host.states[ZgEncounter.thekal] == EncounterState.special);
    run(10_000);
    assert(host.stand == StandState.stand && host.health == 100 && host.preventing, "up again");

    // All three down: the tiger.
    host.states[ZgEncounter.zath] = EncounterState.special;
    host.states[ZgEncounter.lorkhan] = EncounterState.special;
    runtime.raise(h, me, Damaged(EntityRef(7), 5000, 3, 0));
    assert(host.signals.canFind!(s => s.id == ZgSignal.preventRevive), "the Zealots stay down");
    run(1000);
    assert(!host.swings && (host.flags & UnitFlag.uninteractible), "rising");
    run(5000);
    assert(host.casts.canFind(Thekal.tigerForm) && !host.preventing && host.lists[$ - 1] == Thekal.listPhase2);
    runtime.raise(h, me, Died(EntityRef(7)));
    assert(host.states[ZgEncounter.thekal] == EncounterState.done);
}

version (unittest)
{
    class FakeZgCopy : BlackHole!InstanceHost
    {
        Signal[] signals;
        bool[ulong] opened;
        EntityRef[] summoned;
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
        override bool hostLocationOf(EntityRef who, out Location at) { at = Location(0, (who.guid & 1) ? -1650 : -1605, 41); return true; }
        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(entry) << 24) | summoned.length);
            return summoned[$ - 1];
        }
    }
}

/// Zul'Gurub's copy: each priest's fall weakens Hakkar; Arlokk's forcefield closes while she fights and
/// her prowlers come from both sides; Mandokir comes down when his keepers are slain.
unittest
{
    alias self = dmangos.scripts.zulgurub;
    auto runtime = ScriptRuntime.of!self();
    auto copy = new FakeZgCopy;
    auto c = InstanceContext(copy);
    auto h = runtime.create(ScriptKind.instance, "instance_zulgurub");
    const hakkar = EntityRef(0xF130_0000_0000_0001UL | (ulong(npcHakkar) << 24));
    const mandokir = EntityRef(0xF130_0000_0000_0002UL | (ulong(npcMandokir) << 24));
    const field = EntityRef(0xF110_0000_0000_0003UL | (ulong(goForcefield) << 24));
    runtime.raise(h, c, CreatureLoaded(hakkar));
    runtime.raise(h, c, CreatureLoaded(mandokir));
    runtime.raise(h, c, ObjectLoaded(field));
    foreach (i; 0 .. 4)
        runtime.raise(h, c, CreatureLoaded(EntityRef(0xF130_0000_0000_0010UL | (ulong(npcPantherTrigger) << 24) | i)));
    assert(copy.opened[field.guid]);

    runtime.raise(h, c, Signal(EntityRef.init, ZgEncounter.venoxis, EncounterState.done));
    assert(copy.signals[$ - 1] == Signal(hakkar, ZgSignal.powerDown, 0));

    runtime.raise(h, c, Signal(EntityRef.init, ZgEncounter.arlokk, EncounterState.inProgress));
    assert(!copy.opened[field.guid], "closed while she fights");
    runtime.raise(h, c, Signal(EntityRef.init, ZgSignal.prowlers, 1));
    runtime.tick(h, c, 100);
    assert(copy.summoned.length == 2, "one from each side");
    runtime.raise(h, c, Signal(EntityRef.init, ZgEncounter.arlokk, EncounterState.done));
    assert(copy.opened[field.guid]);
    runtime.tick(h, c, 10_000);
    assert(copy.summoned.length == 2, "no more once she has fallen");

    runtime.raise(h, c, Signal(EntityRef.init, ZgEncounter.ohgan, EncounterState.special));
    assert(copy.signals[$ - 1] == Signal(mandokir, ZgSignal.comeDown, 0));
}

/// Arlokk's fight saved without her (an older save, or a crash before the gong's summons came) failed when the copy
/// comes back: her forcefield opens, her prowlers stop, and the gong may call her again.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;

    alias self = dmangos.scripts.zulgurub;
    auto runtime = ScriptRuntime.of!self();
    auto copy = new FakeZgCopy;
    auto c = InstanceContext(copy);
    auto h = runtime.create(ScriptKind.instance, "instance_zulgurub");
    runtime.raise(h, c, Signal(EntityRef.init, ZgEncounter.arlokk, EncounterState.inProgress));
    runtime.raise(h, c, Signal(EntityRef.init, ZgSignal.prowlers, 1));
    ByteWriter saved;
    runtime.save(h, saved);

    auto back = runtime.create(ScriptKind.instance, "instance_zulgurub");
    auto reader = ByteReader(saved.data);
    assert(runtime.load(back, reader));
    auto again = new FakeZgCopy;
    auto restored = InstanceContext(again);
    runtime.raise(back, restored, Restored());
    assert(!restored.waitingForPlayer && restored.checkpointRequested);
    const field = EntityRef(0xF110_0000_0000_0003UL | (ulong(goForcefield) << 24));
    runtime.raise(back, restored, ObjectLoaded(field));
    foreach (i; 0 .. 4)
        runtime.raise(back, restored, CreatureLoaded(EntityRef(0xF130_0000_0000_0010UL | (ulong(npcPantherTrigger) << 24) | i)));
    runtime.tick(back, restored, 10_000);
    assert(again.opened[field.guid], "her forcefield stays shut");
    assert(again.summoned.length == 0, "her prowlers come on without her");
    auto q = InstanceContext(again);
    runtime.raise(back, q, Asked(EntityRef.init, ZgEncounter.arlokk));
    assert(q.answerGiven == EncounterState.failed, "her fight, saved without her, stays under way: the gong refuses");
}

/// Mandokir's gaze: its player is told; gaining threat on him while it lasts, they are charged when it ends.

/**
 * Hakkar's Blood Siphon (`spell_hakkar_blood_siphon`, 24324): each raider it reaches casts a siphon back at him
 * (CMaNGOS's `BloodSiphon`): its blood into him (24322, a health funnel), or, poisoned by a Son of Hakkar's
 * Poisonous Blood (24321), its poison (24323, damage over time to him).
 */
@spell("spell_hakkar_blood_siphon")
struct HakkarBloodSiphon
{
    enum uint poisonousBlood = 24321, siphon = 24322, poisonedSiphon = 24323;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect != 0 || !e.target || e.target == e.caster)
            return;
        it.consume();
        it.castSpell(e.target, it.hasAura(e.target, poisonousBlood) ? poisonedSiphon : siphon, e.caster, true);
    }
}

unittest
{
    import std.algorithm.searching : canFind;
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptKind, ScriptRuntime;

    static class FakeMandokir : BlackHole!CreatureHost
    {
        bool gazed;
        float threat = 100;
        uint[] casts;
        int[] said;
        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(11_382) << 24)); }
        override size_t hostThreatList(EntityRef[] into) { into[0] = EntityRef(7); return 1; }
        override bool hostHasAura(EntityRef who, uint spell) { return who == EntityRef(7) && gazed && spell == Mandokir.threateningGaze; }
        override float hostThreatOf(EntityRef) { return threat; }
        override bool hostAlive(EntityRef) { return true; }
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override ActionResult hostSay(int text, EntityRef) { said ~= text; return ActionResult.ok; }
    }

    alias self = dmangos.scripts.zulgurub;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeMandokir;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_mandokir");
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    host.gazed = true;
    runtime.tick(h, me, 500);
    assert(host.said.canFind(Mandokir.sayWatch));
    host.gazed = false; // it ended; they kept still
    runtime.tick(h, me, 500);
    assert(!host.casts.canFind(Mandokir.chargeGaze));
    host.gazed = true;
    runtime.tick(h, me, 500);
    host.threat = 150; // they struck him while watched
    host.gazed = false;
    runtime.tick(h, me, 500);
    assert(host.casts.canFind(Mandokir.chargeGaze));
}
