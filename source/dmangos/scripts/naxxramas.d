/**
 * Naxxramas (map 533): the copy's script (its fifteen encounters and the doors of its four quarters, the
 * eyes and portals each quarter's end opens, the Four Horsemen's chest, Sapphiron's birth and the way to
 * Kel'Thuzad), its area triggers, and the bosses: Anub'Rekhan, Grand Widow Faerlina, Maexxna and her web
 * wraps, Noth the Plaguebringer, Heigan the Unclean, Loatheb, Instructor Razuvious, Gothik the Harvester,
 * the Four Horsemen, Patchwerk, Grobbulus, Gluth, Stalagg, Feugen and Thaddius, Sapphiron and Kel'Thuzad
 * with his Guardians of Icecrown, and the Stoneskin Gargoyles, Living Poison and Diseased Maggots.
 *
 * Maexxna's Web Wrap throws up to three players to the invisible men on her walls (`npc_invible_man`), who
 * wrap them there; Kel'Thuzad dispels the shackles when more than three of his Guardians of Icecrown are
 * shackled (`event_naxxramas`, which also carries Gluth's Decimate).
 *
 * The encounter tests exercise player and creature control, Heigan's floor sections and ice-block shelter.
 * Gluth's original Decimate trigger is still under investigation.
 */
module dmangos.scripts.naxxramas;

import core.time : Duration;

import dmangos.script;
import dmangos.script.state : AppendedSince, appended;

/// Where `who` is, as `ctx` sees it (`Location.init` if it is not here).
private Location where(C)(ref C ctx, EntityRef who)
{
    Location at;
    ctx.locationOf(who, at);
    return at;
}

/// The copy's encounters (CMaNGOS's `TYPE_*`).
enum NaxxEncounter : ubyte
{
    anubRekhan,
    faerlina,
    maexxna,
    noth,
    heigan,
    loatheb,
    razuvious,
    gothik,
    fourHorsemen,
    patchwerk,
    grobbulus,
    gluth,
    thaddius,
    sapphiron,
    kelthuzad,
}

/// Creatures and objects of the copy.
enum : uint
{
    npcAnubRekhan = 15_956,
    npcFaerlina = 15_953,
    npcGluth = 15_932,
    npcThaddius = 15_928,
    npcStalagg = 15_929,
    npcFeugen = 15_930,
    npcMograine = 16_062,
    npcZeliek = 16_063,
    npcThane = 16_064,
    npcBlaumeux = 16_065,
    npcSapphiron = 15_989,
    npcKelthuzad = 15_990,
    npcGothik = 16_060,
    npcSubBossTrigger = 16_137,
    npcWorldTrigger = 15_384,
    npcZombieChow = 16_360,
    npcCryptGuard = 16_573,
    npcSpiderling = 17_055,
    npcWebWrap = 16_486,
    npcPlaguedWarrior = 16_984,
    npcPlaguedChampion = 16_983,
    npcPlaguedGuardian = 16_981,
    npcSpore = 16_286,
    npcFalloutSlime = 16_290,
    npcGrobbulusCloud = 16_363,
    npcUnrelentingTrainee = 16_124,
    npcUnrelentingKnight = 16_125,
    npcUnrelentingRider = 16_126,
    npcSpectralTrainee = 16_127,
    npcSpectralKnight = 16_148,
    npcSpectralHorse = 16_149,
    npcSpectralRider = 16_150,
    goGothikCombatGate = 181_170,
    npcSoldierFrozen = 16_427,
    npcUnstoppableAbom = 16_428,
    npcSoulWeaver = 16_429,
    npcGuardianIcecrown = 16_441,
    npcInvisibleMan = 17_286,

    goSapphironBirth = 181_356,
    goIceBlock = 181_247,
    goChestHorsemen = 181_366,
}

/// What scripts of the copy say to each other, beyond the encounters' states (ids 0 .. 14).
enum NaxxSignal : uint
{
    webWrapped = 100,   /// Maexxna to a web wrap: it holds the player of guid `value`
    addFell = 101,      /// Stalagg or Feugen to the other: I am down (fake death)
    addsDone = 102,     /// the copy (or an add) to Thaddius: both are dead; awake
    reviveAdd = 103,    /// the other's window passed: rise again
    startKt = 104,      /// the copy to Kel'Thuzad: the fight begins
    faerlinaIntro = 105, /// the copy to Faerlina: players came near
    webWrapPull = 106,  /// Maexxna to an invisible man: the player of guid `value` is thrown to you; wrap them
    clearShackles = 107, /// the copy to Kel'Thuzad: too many of his guardians are shackled
    freezePlayer = 108, clearIceBlocks = 109, chains = 110,
    magneticPull = 111, /// the copy to an add: its victim was pulled away (`value`: incoming player's guid)
    gothikWave = 112,    /// a scheduled wave of living adds (`value`: their entry)
    saveGothik = 113,    /// the boss moved to the floor or changed sides
    saveSapphiron = 114, /// Sapphiron to the copy: a phase, a timer or a cast changed (checkpoint me)
    triggerBase = 1000, /// an area trigger: `triggerBase + id`
}

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/// What every boss of the copy shares: its encounter under way, failed (home again), done; its aggro, slay
/// and death lines (`broadcast_text`, `aggroLines` one at random) if it has them.
private enum encounterOf(string which) = `
    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(` ~ which ~ `, EncounterState.inProgress);
        static if (__traits(hasMember, typeof(this), "aggroLines"))
            me.sayText(aggroLines[me.random(cast(uint) aggroLines.length)]);
        static if (__traits(hasMember, typeof(this), "engaged"))
            engaged(me, e);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        static if (__traits(hasMember, typeof(this), "deathLine"))
            me.sayText(deathLine);
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

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        static if (__traits(hasMember, typeof(this), "slayLine"))
            if (e.victim.isPlayer)
                me.sayText(slayLine);
    }
`;

/// The quarters' doors and what opens them, by entry.
private struct NaxxDoor
{
    uint entry;
    /// Open when: `after` is done (or none), and `during` is not under way (or none).
    byte after, during;
}

private static immutable NaxxDoor[] naxxDoors = [
    NaxxDoor(181_126, -1, NaxxEncounter.anubRekhan),           // Anub'Rekhan's door
    NaxxDoor(181_195, NaxxEncounter.anubRekhan, -1),           // his gate on
    NaxxDoor(181_235, -1, NaxxEncounter.faerlina),             // Faerlina's web
    NaxxDoor(181_167, NaxxEncounter.faerlina, -1),             // to the outer ring
    NaxxDoor(181_209, NaxxEncounter.faerlina, -1),             // before Maexxna
    NaxxDoor(181_197, -1, NaxxEncounter.maexxna),              // Maexxna's inner door
    NaxxDoor(181_200, -1, NaxxEncounter.noth),                 // Noth's entry
    NaxxDoor(181_201, NaxxEncounter.noth, -1),                 // his exit
    NaxxDoor(181_202, NaxxEncounter.noth, NaxxEncounter.heigan), // Heigan's entry
    NaxxDoor(181_496, NaxxEncounter.heigan, -1),               // the hallway past Heigan
    NaxxDoor(181_241, -1, NaxxEncounter.loatheb),              // Loatheb's door
    NaxxDoor(181_124, -1, NaxxEncounter.gothik),               // Gothik's entry gate
    NaxxDoor(goGothikCombatGate, -1, NaxxEncounter.gothik),               // his combat gate
    NaxxDoor(181_125, NaxxEncounter.gothik, -1),               // his exit
    NaxxDoor(181_119, NaxxEncounter.gothik, NaxxEncounter.fourHorsemen), // the Horsemen's door
    NaxxDoor(181_123, NaxxEncounter.patchwerk, -1),            // past Patchwerk
    NaxxDoor(181_120, NaxxEncounter.gluth, -1),                // past Gluth
    NaxxDoor(181_121, NaxxEncounter.gluth, NaxxEncounter.thaddius), // Thaddius' door
    NaxxDoor(181_225, NaxxEncounter.sapphiron, -1),            // the waterfall to Kel'Thuzad
    NaxxDoor(181_228, -1, NaxxEncounter.kelthuzad),            // Kel'Thuzad's exit
    // The eyes of each quarter, opened by its end.
    NaxxDoor(181_212, NaxxEncounter.maexxna, -1), NaxxDoor(181_233, NaxxEncounter.maexxna, -1),
    NaxxDoor(181_211, NaxxEncounter.loatheb, -1), NaxxDoor(181_231, NaxxEncounter.loatheb, -1),
    NaxxDoor(181_210, NaxxEncounter.fourHorsemen, -1), NaxxDoor(181_230, NaxxEncounter.fourHorsemen, -1),
    NaxxDoor(181_213, NaxxEncounter.thaddius, -1), NaxxDoor(181_232, NaxxEncounter.thaddius, -1),
];

/// The portals home each quarter's end opens.
private static immutable uint[4] portals = [181_575, 181_577, 181_578, 181_576];
private static immutable NaxxEncounter[4] wingEnds = [NaxxEncounter.maexxna, NaxxEncounter.loatheb,
    NaxxEncounter.fourHorsemen, NaxxEncounter.thaddius];

/// What the copy remembers: its encounters (saved in `instance.data`).
@instance("instance_naxxramas")
struct Naxxramas
{
    enum int sayThaddiusGreet = -1_533_029;
    enum uint triggerKelthuzad = 4112, triggerThaddiusDoor = 4113, triggerFaerlinaIntro = 4115,
        triggerFrostwyrmTele = 4156;
    enum uint sayFaerlinaIntro = 12_852;
    static immutable sapphironAt = Location(3521.48f, -5234.87f, 137.626f, 4.53329f);
    static immutable constructPlatforms = Location(3479, -2964, 312);

    EncounterState[NaxxEncounter.max + 1] encounters;
    ubyte horsemenKilled;
    bool faerlinaIntroDone;

    @transient EntityRef[naxxDoors.length] doors;
    @transient EntityRef thaddius, kelthuzad, faerlina, sapphiron;

    /// The events of `event_naxxramas`: Gluth's Decimate; Kel'Thuzad's guardians counted from now; a guardian shackled.
    enum uint decimateEvent = 10_495, clearShacklesEvent = 10_536, guardianShackleEvent = 10_537;
    /// How many shackled Guardians of Icecrown Kel'Thuzad lets be.
    enum ubyte maxShackles = 3;
    ubyte shackled; /// guardians that said so since the last check

    enum Step : ubyte { sapphiron, shackles, tankSwap }
    Schedule!Step steps;

    // Appended to keep earlier lockout saves readable.
    @appended EntityRef[] gothikAdds;
    @transient EntityRef gothik;
    @transient bool recoveringGothik;
    @transient float gothikDividerY = -3360.78f; // center of the combat gate in Classic-DB
    /// The ice blocks of Sapphiron's air phase (saved with his fight under way; appended after Gothik's adds).
    @AppendedSince(2) EntityRef[] iceBlocks;

    private bool gothikActive() const
    {
        const state = encounters[NaxxEncounter.gothik];
        return state == EncounterState.inProgress || state == EncounterState.special;
    }

    private bool doorOpen(size_t i) const
    {
        const d = naxxDoors[i];
        if (d.after >= 0 && encounters[d.after] != EncounterState.done)
            return false;
        if (d.during == NaxxEncounter.gothik && gothikActive)
            return d.entry == goGothikCombatGate && encounters[NaxxEncounter.gothik] == EncounterState.special;
        return d.during < 0 || encounters[d.during] != EncounterState.inProgress;
    }

    private void updateDoors(ref InstanceContext copy)
    {
        foreach (i, d; doors)
            if (d)
                copy.door(d, doorOpen(i));
    }

    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        import std.algorithm.searching : canFind;

        foreach (i, d; naxxDoors)
            if (e.object.entry == d.entry)
            {
                doors[i] = e.object;
                if (d.entry == goGothikCombatGate)
                {
                    Location gate;
                    if (copy.locationOf(e.object, gate))
                        gothikDividerY = gate.y;
                }
                copy.door(e.object, doorOpen(i));
            }
        // A clean handoff brings the air phase's blocks in without a signal: they stay in the checkpoint.
        if (e.object.entry == goIceBlock && sapphironActive && iceBlocks.canFind(e.object))
            copy.checkpointObject(e.object);
    }

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case npcGothik:
            gothik = e.creature;
            break;
        case npcThaddius:
            thaddius = e.creature;
            break;
        case npcKelthuzad:
            kelthuzad = e.creature;
            break;
        case npcFaerlina:
            faerlina = e.creature;
            break;
        case npcSapphiron:
            sapphiron = e.creature;
            if (sapphironActive) // a clean handoff brings him in without a signal: he stays in the checkpoint
                copy.checkpointCreature(sapphiron);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, const ref PlayerEntered e)
    {
        // The portals of the quarters ended stand open; Sapphiron, once born, is there.
        foreach (i, wing; wingEnds)
            if (encounters[wing] == EncounterState.done)
                copy.respawnObject(portals[i]);
        const frostwyrm = encounters[NaxxEncounter.sapphiron];
        const sapphironHere = sapphiron && copy.alive(sapphiron);
        if ((frostwyrm == EncounterState.special || frostwyrm == EncounterState.failed) && !sapphironHere
            && !steps.pending(Step.sapphiron))
            steps.after(Step.sapphiron, 0.msecs); // born, and gone with the copy (a restart, a crash): he comes again
        else if (frostwyrm == EncounterState.inProgress && sapphironHere)
            copy.zoneCombat(sapphiron); // back in the copy (after a crash, say): back in his fight
        if (gothikActive)
        {
            if (recoveringGothik)
            {
                recoveringGothik = false;
                if (gothik && !copy.alive(copy.victimOf(gothik)))
                    copy.attack(gothik, e.player);
            }
            foreach (add; gothikAdds)
                if (copy.alive(add) && !copy.alive(copy.victimOf(add)))
                    if (const target = gothikTarget(copy, where(copy, add)))
                        copy.attack(add, target);
        }
    }

    /// A restore during Stalagg and Feugen's fight keeps their swap going: adds restored still fighting
    /// never enter combat again to restart it. Until a swap finds them fighting, a fresh pull restarts it.
    @transient bool tankSwapRestored;

    void on(ref InstanceContext copy, const ref Restored e)
    {
        steps.cancel(Step.tankSwap);
        tankSwapRestored = encounters[NaxxEncounter.thaddius] == EncounterState.inProgress;
        if (tankSwapRestored)
            steps.every(Step.tankSwap, 21.seconds);
        if (gothikActive)
        {
            import std.algorithm.mutation : remove;

            if (copy.entryKilled(npcGothik))
                setGothik(copy, EncounterState.done);
            else if (copy.hasSavedCreature(npcGothik))
            {
                recoveringGothik = true;
                gothikAdds = gothikAdds.remove!(add => !copy.hasSavedCreature(add));
                copy.waitForPlayer();
            }
            else
                setGothik(copy, EncounterState.failed);
        }
        restoreSapphiron(copy);
    }

    private bool sapphironActive() const
    {
        return encounters[NaxxEncounter.sapphiron] == EncounterState.inProgress;
    }

    /**
     * Sapphiron's encounter in `state`. Born (`special`), he comes 22 seconds later. While his fight is under way he
     * and the ice blocks of his air phase are saved with the copy (a worker's crash resumes it, `Restored`); a
     * wipe or his death lets them go, and the blocks melt. His death is for the rest of the lockout.
     */
    private void setSapphiron(ref InstanceContext copy, EncounterState state)
    {
        const was = encounters[NaxxEncounter.sapphiron];
        if (was == EncounterState.done || (state == EncounterState.special && was != EncounterState.notStarted))
            return;
        encounters[NaxxEncounter.sapphiron] = state;
        if (state == EncounterState.special)
            steps.after(Step.sapphiron, 22.seconds);
        else if (sapphironActive)
        {
            if (sapphiron && copy.alive(sapphiron))
                copy.checkpointCreature(sapphiron);
        }
        else
        {
            if (sapphiron)
                copy.releaseCheckpointActor(sapphiron);
            meltIceBlocks(copy);
        }
        updateDoors(copy);
        copy.checkpoint();
    }

    /// The air phase's ice blocks go (he lands, a wipe, his death), and out of the checkpoint.
    private void meltIceBlocks(ref InstanceContext copy)
    {
        foreach (block; iceBlocks)
        {
            copy.releaseCheckpointActor(block);
            copy.despawnObject(block);
        }
        iceBlocks = null;
    }

    /**
     * The copy came back from its save. Born and not come yet, his timer waits for the raid. His fight under way
     * resumes from its checkpoint when a player comes back, with the ice blocks it kept; a fight saved without him
     * (an older save) failed, and he comes again (`PlayerEntered`), as after a wipe.
     */
    private void restoreSapphiron(ref InstanceContext copy)
    {
        import std.algorithm.mutation : remove;

        const state = encounters[NaxxEncounter.sapphiron];
        if (state == EncounterState.special)
            copy.waitForPlayer();
        else if (state == EncounterState.inProgress && copy.hasSavedCreature(npcSapphiron))
        {
            iceBlocks = iceBlocks.remove!(block => !copy.hasSavedCreature(block));
            copy.waitForPlayer();
        }
        else if (state == EncounterState.inProgress)
        {
            encounters[NaxxEncounter.sapphiron] = EncounterState.failed;
            meltIceBlocks(copy);
            copy.checkpoint();
        }
    }

    /// The question whether the way to Sapphiron is open (every quarter ended).
    enum uint askFrostwyrm = 100;

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id <= NaxxEncounter.max)
            copy.answer(encounters[e.id]);
        else if (e.id == askFrostwyrm)
            copy.answer(frostwyrmOpen ? 1 : 0);
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id == NaxxSignal.freezePlayer)
        {
            // The block stands until he lands (`clearIceBlocks`): his breath, held for the raid's return after a
            // crash, must find it there, as it finds the frozen player still frozen.
            Location at;
            if (e.from == sapphiron && copy.locationOf(EntityRef(cast(uint) e.value), at))
                if (const block = copy.summonObject(goIceBlock, at))
                {
                    iceBlocks ~= block;
                    if (sapphironActive)
                        copy.checkpointObject(block); // saved with him as he froze its player
                }
            return;
        }
        if (e.id == NaxxSignal.clearIceBlocks)
            return meltIceBlocks(copy);
        if (e.from.isCreature && e.from.entry == npcSapphiron)
        {
            if (e.id == NaxxEncounter.sapphiron)
            {
                sapphiron = e.from;
                return setSapphiron(copy, cast(EncounterState) e.value);
            }
            if (e.id == NaxxSignal.saveSapphiron)
            {
                if (sapphironActive && copy.alive(e.from))
                {
                    sapphiron = e.from;
                    copy.checkpointCreature(sapphiron);
                }
                return;
            }
        }
        if (e.id == NaxxEncounter.sapphiron)
            return setSapphiron(copy, cast(EncounterState) e.value); // his birth
        if (e.from.entry == npcGothik)
        {
            if (e.id == NaxxEncounter.gothik)
            {
                gothik = e.from;
                setGothik(copy, cast(EncounterState) e.value);
                return;
            }
            if (gothikActive && (e.id == NaxxSignal.gothikWave || e.id == NaxxSignal.saveGothik))
            {
                gothik = e.from;
                if (e.id == NaxxSignal.gothikWave)
                {
                    spawnGothikAdd(copy, cast(uint) e.value, true);
                    if (e.value == npcUnrelentingTrainee)
                        spawnGothikAdd(copy, npcUnrelentingTrainee, true);
                }
                copy.checkpointCreature(gothik);
                return;
            }
        }
        if (e.id > NaxxSignal.triggerBase)
            return trigger(copy, e.id - NaxxSignal.triggerBase);
        if (e.id > NaxxEncounter.max)
            return;
        const which = cast(NaxxEncounter) e.id;
        auto state = cast(EncounterState) e.value;
        if (which == NaxxEncounter.fourHorsemen)
        {
            // Four deaths make the encounter.
            if (state == EncounterState.done && ++horsemenKilled < 4)
                return;
            if (state == EncounterState.failed)
                horsemenKilled = 0;
            if (state == EncounterState.done)
                copy.respawnObject(goChestHorsemen, 30 * 60);
        }
        if (which == NaxxEncounter.thaddius)
        {
            if (state != EncounterState.inProgress)
            {
                steps.cancel(Step.tankSwap);
                tankSwapRestored = false;
            }
            else if ((e.from.entry == npcFeugen || e.from.entry == npcStalagg)
                && (tankSwapRestored || !steps.pending(Step.tankSwap)))
            {
                // A pull after a restore found the adds idle: time the swap from this pull.
                tankSwapRestored = false;
                steps.every(Step.tankSwap, 21.seconds);
            }
        }
        if ((which == NaxxEncounter.thaddius || which == NaxxEncounter.fourHorsemen) && encounters[which] == state)
            return;
        encounters[which] = state;
        foreach (i, wing; wingEnds)
            if (wing == which && state == EncounterState.done)
                copy.respawnObject(portals[i], 30 * 60);
        if (which == NaxxEncounter.thaddius && state == EncounterState.special && thaddius)
            copy.signal(thaddius, NaxxSignal.addsDone);
        updateDoors(copy);
    }

    /// Gothik gave up his fight, or his checkpoint could not bring him back: his gates must not stay shut on the raid.
    void on(ref InstanceContext copy, const ref CreatureEvaded e)
    {
        if (e.creature.entry == npcGothik && gothikActive)
            setGothik(copy, EncounterState.failed);
        if (e.creature.entry == npcSapphiron && sapphironActive)
            setSapphiron(copy, EncounterState.failed); // he comes again for the next pull (`PlayerEntered`)
    }

    private void setGothik(ref InstanceContext copy, EncounterState state)
    {
        if (encounters[NaxxEncounter.gothik] == EncounterState.done)
            return;
        encounters[NaxxEncounter.gothik] = state;
        updateDoors(copy);
        if (gothikActive)
        {
            if (gothik)
                copy.checkpointCreature(gothik);
        }
        else
        {
            if (gothik)
                copy.releaseCheckpointActor(gothik);
            foreach (add; gothikAdds)
            {
                copy.releaseCheckpointActor(add);
                if (copy.alive(add))
                    copy.despawn(add);
            }
            gothikAdds = null;
        }
        copy.checkpoint();
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        if (e.creature.entry == npcGothik && !e.summoned)
            return setGothik(copy, EncounterState.done);
        if (e.creature.entry == npcSapphiron)
            return setSapphiron(copy, EncounterState.done);

        const index = gothikAdds.countUntil(e.creature);
        if (index < 0)
            return;
        gothikAdds = gothikAdds.remove(index);
        copy.releaseCheckpointActor(e.creature);
        switch (e.creature.entry)
        {
        case npcUnrelentingTrainee:
            spawnGothikAdd(copy, npcSpectralTrainee, false);
            break;
        case npcUnrelentingKnight:
            spawnGothikAdd(copy, npcSpectralKnight, false);
            break;
        case npcUnrelentingRider:
            spawnGothikAdd(copy, npcSpectralRider, false);
            spawnGothikAdd(copy, npcSpectralHorse, false);
            break;
        default:
            break;
        }
    }

    private EntityRef gothikTarget(ref InstanceContext copy, Location from)
    {
        EntityRef[40] raid;
        EntityRef target;
        float nearest = 100.0f ^^ 2;
        foreach (player; raid[0 .. copy.players(raid[])])
        {
            Location at;
            if (!copy.alive(player) || !copy.locationOf(player, at))
                continue;
            if (encounters[NaxxEncounter.gothik] != EncounterState.special
                && (at.y <= gothikDividerY) != (from.y <= gothikDividerY))
                continue;
            const distance = (at.x - from.x) ^^ 2 + (at.y - from.y) ^^ 2 + (at.z - from.z) ^^ 2;
            if (distance < nearest)
            {
                nearest = distance;
                target = player;
            }
        }
        return target;
    }

    private void spawnGothikAdd(ref InstanceContext copy, uint entry, bool livingSide)
    {
        // Use the floor anchors in that half of the room. The higher triggers are on the balconies.
        Location at = Gothik.sides[livingSide ? 0 : 1];
        EntityRef[13] anchors;
        Location[13] points;
        uint count;
        foreach (anchor; anchors[0 .. copy.creaturesNear(at, npcSubBossTrigger, 90, anchors[])])
        {
            const where_ = where(copy, anchor);
            if ((where_.y <= gothikDividerY) == livingSide && where_.z < at.z + 5)
                points[count++] = where_;
        }
        if (count)
            at = points[copy.random(count)];
        if (const add = copy.summon(entry, at, 0, gothikTarget(copy, at)))
        {
            gothikAdds ~= add;
            copy.checkpointCreature(add);
        }
    }

    private void trigger(ref InstanceContext copy, uint id)
    {
        switch (id)
        {
        case triggerKelthuzad:
            const kt = encounters[NaxxEncounter.kelthuzad];
            if ((kt == EncounterState.notStarted || kt == EncounterState.failed) && kelthuzad)
            {
                encounters[NaxxEncounter.kelthuzad] = EncounterState.inProgress;
                copy.signal(kelthuzad, NaxxSignal.startKt);
                updateDoors(copy);
            }
            break;
        case triggerFaerlinaIntro:
            if (!faerlinaIntroDone && encounters[NaxxEncounter.faerlina] == EncounterState.notStarted && faerlina)
            {
                faerlinaIntroDone = true;
                copy.signal(faerlina, NaxxSignal.faerlinaIntro);
            }
            break;
        case triggerThaddiusDoor:
            if (encounters[NaxxEncounter.thaddius] == EncounterState.notStarted && thaddius)
                copy.say(thaddius, sayThaddiusGreet);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, const ref EventHappened e)
    {
        switch (e.event)
        {
        case decimateEvent:
            // Gluth's own script brings the zombie chows to him and has him eat them; the event's database
            // script (which would too) does not follow.
            copy.consume();
            break;
        case clearShacklesEvent:
            copy.consume();
            shackled = 0;
            steps.every(Step.shackles, 2.seconds);
            break;
        case guardianShackleEvent:
            copy.consume();
            ++shackled;
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, Step step)
    {
        final switch (step)
        {
        case Step.sapphiron:
            // Born, or failed and gone with the copy: he comes (once: one a clean handoff brought is kept).
            const state = encounters[NaxxEncounter.sapphiron];
            EntityRef[1] here;
            if ((state != EncounterState.special && state != EncounterState.failed) || !copy.playerCount)
                break;
            if (copy.creaturesNear(sapphironAt, npcSapphiron, 150, here[]))
                sapphiron = here[0];
            else
                sapphiron = copy.summon(npcSapphiron, sapphironAt);
            break;
        case Step.shackles:
            // Every two seconds: more than three guardians shackled, and Kel'Thuzad breaks the shackles.
            if (encounters[NaxxEncounter.kelthuzad] != EncounterState.inProgress)
                steps.cancel(Step.shackles);
            else if (shackled > maxShackles && kelthuzad)
                copy.signal(kelthuzad, NaxxSignal.clearShackles);
            shackled = 0;
            break;
        case Step.tankSwap:
            swapConstructTanks(copy);
            break;
        }
    }

    private void swapConstructTanks(ref InstanceContext copy)
    {
        // Look up the current actors so the timer also works after a clean copy handoff.
        EntityRef[1] west, east;
        if (!copy.creaturesNear(constructPlatforms, npcStalagg, 120, west[])
            || !copy.creaturesNear(constructPlatforms, npcFeugen, 120, east[]))
            return;
        const stalagg = west[0], feugen = east[0];
        if ((copy.unitFlagsOf(stalagg) | copy.unitFlagsOf(feugen)) & UnitFlag.uninteractible)
            return;
        // Snapshot both victims before either spell moves a player or changes a threat list.
        const stalaggTank = copy.victimOf(stalagg), feugenTank = copy.victimOf(feugen);
        if (!stalaggTank.isPlayer || !feugenTank.isPlayer || stalaggTank == feugenTank
            || !copy.alive(stalaggTank) || !copy.alive(feugenTank))
            return;
        tankSwapRestored = false; // the restored timer met the fight still on

        enum uint pull = 28_337, stalaggMarker = 28_338, feugenMarker = 28_339;
        copy.castSpell(stalagg, stalaggMarker);
        copy.castSpell(feugen, feugenMarker);
        const stalaggTankMoved = copy.castSpell(feugen, pull, stalaggTank) == ActionResult.ok;
        const feugenTankMoved = copy.castSpell(stalagg, pull, feugenTank) == ActionResult.ok;
        if (stalaggTankMoved)
            copy.signal(stalagg, NaxxSignal.magneticPull, feugenTankMoved ? cast(int) feugenTank.guid : 0);
        if (feugenTankMoved)
            copy.signal(feugen, NaxxSignal.magneticPull, stalaggTankMoved ? cast(int) stalaggTank.guid : 0);
    }

    /// Whether the way to Sapphiron is open: every quarter ended.
    bool frostwyrmOpen() const
    {
        foreach (wing; wingEnds)
            if (encounters[wing] != EncounterState.done)
                return false;
        return true;
    }
}

/// Naxxramas' scripted events (`event_naxxramas`): Gluth's Decimate and the shackling of Kel'Thuzad's guardians;
/// the copy's script handles them (`EventHappened`), and the event's own script lets them through to it.
@scriptedEvent("event_naxxramas")
struct NaxxramasEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

/// Naxxramas' area triggers: Kel'Thuzad's chamber, Faerlina's greeting, Thaddius' door, and the way up to
/// Sapphiron (only with every quarter ended).
@areaTrigger("at_naxxramas")
struct AtNaxxramas
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (e.trigger == Naxxramas.triggerFrostwyrmTele && !at.askDungeon(Naxxramas.askFrostwyrm))
            return at.consume(); // the quarters first
        at.signalDungeon(NaxxSignal.triggerBase + e.trigger);
    }
}

/// The Anub door: opening it starts Anub'Rekhan's greeting.
@gameObject("go_anub_door")
struct AnubDoor
{
    void on(ref GameObjectContext door, const ref ObjectUsed e)
    {
    }
}

/// The Frostwyrm's birth: used once the quarters are ended, Sapphiron comes.
@gameObject("go_sapphiron_birth")
struct SapphironBirth
{
    void on(ref GameObjectContext birth, const ref ObjectUsed e)
    {
        if (birth.askDungeon(NaxxEncounter.sapphiron) != EncounterState.notStarted)
            return birth.consume();
        birth.signalDungeon(NaxxEncounter.sapphiron, EncounterState.special);
    }
}

// ---------------------------------------------------------------------------
// The Arachnid Quarter
// ---------------------------------------------------------------------------

/// Anub'Rekhan: Impale, Locust Swarm (a Crypt Guard comes after it), and corpse scarabs (left out).
@creature("boss_anubrekhan")
struct AnubRekhan
{
    static immutable uint[3] aggroLines = [13_000, 13_002, 13_003];
    enum uint slayLine = 13_005;
    enum : uint { doubleAttack = 18_943, impale = 28_783, locustSwarm = 28_785 }
    enum Step : ubyte { impale, swarm, guard }
    Schedule!Step steps;
    EntityRef[4] guards;

    mixin(encounterOf!"NaxxEncounter.anubRekhan");

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
    }

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.impale, 15.seconds);
        steps.after(Step.swarm, between(me, 80_000, 120_000));
        steps.after(Step.guard, 20.seconds);
    }

    void reset(ref CreatureContext me)
    {
        foreach (ref g; guards)
            if (g)
            {
                me.despawn(g);
                g = EntityRef.init;
            }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.impale:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(impale, target) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.swarm:
            if (me.castSelf(locustSwarm) == ActionResult.ok)
            {
                steps.after(Step.guard, 3.seconds);
                steps.after(step, between(me, 80_000, 120_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.guard:
            foreach (ref g; guards)
                if (!g || !me.alive(g))
                {
                    g = me.summon(npcCryptGuard, Location.init, 0, me.selectTarget(Pick.random, PickFilter.player));
                    break;
                }
            break;
        }
    }

    /// A guard slain frees its place. (Summoned to go when dead, it leaves the map as it dies, and `alive` of a
    /// creature not here says yes: after four guards no more came.)
    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        foreach (ref g; guards)
            if (g == e.summoned)
                g = EntityRef.init;
    }
}

/// A controlled worshipper can sacrifice itself beside Faerlina to suppress her poison and frenzy.
@spell("spell_faerlina_widow_embrace")
struct WidowsEmbrace
{
    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (e.effect == 0 && e.target.entry == 15953)
            it.removeAura(e.target, 28798);
    }

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect == 1 && e.caster.entry == 16506)
            it.castSpell(e.caster, 28748, e.caster);
    }
}

@creature("boss_faerlina")
struct Faerlina
{
    static immutable uint[1] aggroLines = [12_856];
    enum uint slayLine = 12_854, deathLine = 12_853, emoteFrenzy = 1191;
    enum : uint { poisonboltVolley = 28_796, enrage = 28_798, rainOfFire = 28_794 }
    enum Step : ubyte { volley, rain, enrage }
    Schedule!Step steps;

    mixin(encounterOf!"NaxxEncounter.faerlina");

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == NaxxSignal.faerlinaIntro)
            me.sayText(Naxxramas.sayFaerlinaIntro);
    }

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.volley, 8.seconds);
        steps.after(Step.rain, between(me, 6000, 18_000));
        steps.after(Step.enrage, 60.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.volley:
            if (me.hasAura(me.self, 28732))
            {
                steps.after(step, 1.seconds);
                break;
            }
            steps.after(step, me.castSelf(poisonboltVolley) == ActionResult.ok ? between(me, 8000, 15_000) : retry);
            break;
        case Step.rain:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(rainOfFire, target) == ActionResult.ok ? between(me, 6000, 18_000) : retry);
            break;
        case Step.enrage:
            if (me.hasAura(me.self, 28732))
            {
                steps.after(step, 1.seconds);
                break;
            }
            if (me.castSelf(enrage) == ActionResult.ok)
            {
                me.sayText(12_857 + me.random(3));
                me.sayText(emoteFrenzy);
                steps.after(step, 60.seconds);
            }
            else
                steps.after(step, retry);
            break;
        }
    }
}

/// Maexxna: Web Wrap (a player cocooned on the wall until the wrap is broken), Web Spray, Poison Shock,
/// Necrotic Poison, spiderlings every thirty seconds, and a frenzy below 30%.
@creature("boss_maexxna")
struct Maexxna
{
    enum uint emoteFrenzy = 1191;
    enum : uint
    {
        doubleAttack = 19_818,
        webSpray = 29_484,
        poisonShock = 28_741,
        necroticPoison = 28_776,
        frenzy = 28_747,
        webWrapStun = 28_622,
    }
    enum Step : ubyte { wrap, spray, shock, necrotic, spiderlings }
    Schedule!Step steps;
    bool frenzied;

    mixin(encounterOf!"NaxxEncounter.maexxna");

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
    }

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.wrap, 20.seconds);
        steps.after(Step.spray, 40.seconds);
        steps.after(Step.shock, between(me, 10_000, 20_000));
        steps.after(Step.necrotic, between(me, 20_000, 30_000));
        steps.after(Step.spiderlings, 30.seconds);
    }

    void reset(ref CreatureContext me)
    {
        frenzied = false;
        EntityRef[24] adds;
        foreach (entry; [npcSpiderling, npcWebWrap])
            foreach (a; adds[0 .. me.creaturesNearby(entry, 150, adds[])])
                me.despawn(a);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!frenzied && e.after < 30 && me.castSelf(frenzy) == ActionResult.ok)
        {
            frenzied = true;
            me.sayText(emoteFrenzy);
        }
    }

    /// Up to three players (not her victim) thrown to the invisible men on her walls, one each, who wrap them;
    /// with none of them about, a player is wrapped where they stand.
    private void webWrap(ref CreatureContext me)
    {
        EntityRef[6] men;
        auto n = me.creaturesNearby(npcInvisibleMan, 100, men[]);
        EntityRef[3] chosen;
        size_t taken;
        foreach (attempt; 0 .. 8)
        {
            if (taken == chosen.length || (n == 0 && taken == 1))
                break;
            const target = me.selectTarget(Pick.random, PickFilter.player | PickFilter.notVictim);
            if (!target)
                break;
            bool again;
            foreach (c; chosen[0 .. taken])
                again |= c == target;
            if (!again)
                chosen[taken++] = target;
        }
        foreach (target; chosen[0 .. taken])
        {
            if (n == 0)
            {
                me.castSpell(webWrapStun, target, true);
                if (const wrap = me.summon(npcWebWrap, where(me, target)))
                    me.signal(wrap, NaxxSignal.webWrapped, cast(int)(target.guid & 0x7FFF_FFFF));
                continue;
            }
            // A wall of its own (the chosen man taken out of the choice).
            const i = me.random(cast(uint) n);
            const man = men[i];
            men[i] = men[--n];
            me.teleport(target, where(me, man));
            me.signal(man, NaxxSignal.webWrapPull, cast(int)(target.guid & 0x7FFF_FFFF));
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.wrap:
            webWrap(me);
            steps.after(step, 40.seconds);
            break;
        case Step.spray:
            steps.after(step, me.castSelf(webSpray) == ActionResult.ok ? 40.seconds : retry);
            break;
        case Step.shock:
            steps.after(step, me.castSelf(poisonShock) == ActionResult.ok ? between(me, 10_000, 20_000) : retry);
            break;
        case Step.necrotic:
            steps.after(step, me.castSpell(necroticPoison) == ActionResult.ok ? between(me, 20_000, 30_000) : retry);
            break;
        case Step.spiderlings:
            import std.math : cos, sin, PI;

            const at = me.location;
            foreach (i; 0 .. 8)
                me.summon(npcSpiderling, Location(at.x + 12 * cos(i * PI / 4), at.y + 12 * sin(i * PI / 4), at.z), 0,
                    me.selectTarget(Pick.random, PickFilter.player));
            steps.after(step, 30.seconds);
            break;
        }
    }
}

/// An invisible man on Maexxna's walls (`npc_invible_man`): the player she throws to him is wrapped there a few
/// seconds later (stunned, in a Web Wrap that holds them until broken), if still alive.
@creature("npc_invible_man")
struct InvisibleMan
{
    EntityRef victim;
    enum Step : ubyte { wrap }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.combatMovement(false);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != NaxxSignal.webWrapPull)
            return;
        victim = EntityRef(cast(uint) e.value);
        steps.after(Step.wrap, 5.seconds); // they have landed
    }

    void on(ref CreatureContext me, Step step)
    {
        if (victim && me.alive(victim))
        {
            me.castSpell(Maexxna.webWrapStun, victim, true);
            if (const wrap = me.summon(npcWebWrap, where(me, victim)))
                me.signal(wrap, NaxxSignal.webWrapped, cast(int)(victim.guid & 0x7FFF_FFFF));
        }
        victim = EntityRef.init;
    }
}

/// A Naxxramas Military Sub-Boss Trigger (`spell_anchor`): one of the places in Gothik's hall his trainees,
/// knights and riders come from (his script finds them), and the anchor his summoning spells aim at; it stays
/// where it is and keeps out of fights.
@creature("spell_anchor")
struct SubBossAnchor
{
    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.combatMovement(false);
    }
}

/// A Web Wrap: holds its player until broken (or until the player is dead).
@creature("npc_web_wrap")
struct WebWrap
{
    enum uint selfStun = 29_826;
    EntityRef held;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        me.castSelf(selfStun, true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == NaxxSignal.webWrapped)
            held = EntityRef(cast(uint) e.value);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        if (held)
            me.removeAura(held, Maexxna.webWrapStun);
        me.despawn(5000);
    }
}

// ---------------------------------------------------------------------------
// The Plague Quarter
// ---------------------------------------------------------------------------

/**
 * Noth the Plaguebringer: Blink (his hatred forgotten), his curse, Plagued Warriors; every ninety
 * seconds he goes up to his balcony (untouchable) and his skeletal champions and guardians come in
 * waves, longer each time.
 */
@creature("boss_noth")
struct Noth
{
    static immutable uint[3] aggroLines = [13_061, 13_062, 13_063];
    enum uint slayLine = 13_065, deathLine = 13_064, saySummon = 13_067;
    enum : uint { blink = 29_208, cripple = 29_212, curse = 29_213, immuneAll = 29_230 }
    static immutable balcony = Location(2633.49f, -3529.56f, 274.111f, 6.18113f);
    static immutable ground = Location(2685.06f, -3502.37f, 261.315f, 0);

    enum Step : ubyte { warriors, blink, curse, balconyPhase, groundPhase, waves }
    Schedule!Step steps;
    ubyte balconyVisits;
    bool onBalcony;

    mixin(encounterOf!"NaxxEncounter.noth");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        groundSteps(me);
    }

    private void groundSteps(ref CreatureContext me)
    {
        steps.after(Step.warriors, 12.seconds);
        steps.after(Step.blink, between(me, 25_000, 30_000));
        steps.after(Step.curse, between(me, 10_000, 15_000));
        steps.after(Step.balconyPhase, 90.seconds);
    }

    void reset(ref CreatureContext me)
    {
        balconyVisits = 0;
        onBalcony = false;
        me.unitFlags(UnitFlag.uninteractible, false);
        me.removeAura(me.self, immuneAll);
        me.rooted(false);
        me.melee(true);
        EntityRef[32] adds;
        foreach (entry; [npcPlaguedWarrior, npcPlaguedChampion, npcPlaguedGuardian])
            foreach (a; adds[0 .. me.creaturesNearby(entry, 200, adds[])])
                me.despawn(a);
    }

    /// `count` of `entry` near random players.
    private void summonNear(ref CreatureContext me, uint entry, uint count)
    {
        foreach (_; 0 .. count)
            if (const target = me.selectTarget(Pick.random, PickFilter.player))
            {
                const l = where(me, target);
                me.summon(entry, Location(l.x + me.random(10) - 5.0f, l.y + me.random(10) - 5.0f, l.z), 0, target);
            }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.warriors:
            me.sayText(saySummon);
            summonNear(me, npcPlaguedWarrior, 3);
            steps.after(step, 30.seconds);
            break;
        case Step.blink:
            // Those near him crippled, he blinks away, his hatred forgotten.
            me.castSelf(cripple);
            const l = me.location;
            me.castSelf(blink, true);
            me.teleport(Location(l.x + me.random(30) - 15.0f, l.y + me.random(30) - 15.0f, l.z, l.orientation));
            me.resetThreat();
            steps.after(step, between(me, 25_000, 30_000));
            break;
        case Step.curse:
            steps.after(step, me.castSelf(curse) == ActionResult.ok ? between(me, 50_000, 60_000) : retry);
            break;
        case Step.balconyPhase:
            // Up to his balcony: untouchable while his skeletons fight.
            onBalcony = true;
            ++balconyVisits;
            foreach (s; [Step.warriors, Step.blink, Step.curse])
                steps.cancel(s);
            me.teleport(balcony);
            me.castSelf(immuneAll, true);
            me.unitFlags(UnitFlag.uninteractible, true);
            me.melee(false);
            me.rooted(true);
            steps.after(Step.waves, 10.seconds);
            static immutable uint[3] stay = [70_000, 97_000, 120_000];
            steps.after(Step.groundPhase, stay[balconyVisits > 3 ? 2 : balconyVisits - 1].msecs);
            break;
        case Step.waves:
            if (!onBalcony)
                break;
            summonNear(me, balconyVisits == 1 ? npcPlaguedChampion : npcPlaguedGuardian, 2);
            summonNear(me, npcPlaguedChampion, 2);
            steps.after(step, 30.seconds);
            break;
        case Step.groundPhase:
            onBalcony = false;
            steps.cancel(Step.waves);
            me.teleport(ground);
            me.removeAura(me.self, immuneAll);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.rooted(false);
            me.melee(true);
            me.resetThreat();
            if (const target = me.selectTarget(Pick.nearest))
                me.attack(target);
            groundSteps(me);
            steps.after(Step.warriors, 5.seconds);
            break;
        }
    }
}

/// Heigan the Unclean: Decrepit Fever and Mana Burn on the ground for ninety seconds, then 45 seconds on
/// his platform channelling his plague cloud. The fissures erupt faster during the channel.
@creature("boss_heigan")
struct Heigan
{
    static immutable uint[3] aggroLines = [13_041, 13_042, 13_043];
    enum uint slayLine = 13_045, deathLine = 13_044, sayChanneling = 13_049;
    static immutable uint[4] taunts = [13_046, 13_047, 13_048, 13_050];
    enum : uint { decrepitFever = 29_998, manaBurn = 29_310, plagueCloud = 29_350 }
    static immutable platform = Location(2794.61f, -3707.68f, 276.552f, 2.32f);

    enum Step : ubyte { fever, burn, platformPhase, groundPhase, taunt, wave }
    Schedule!Step steps;
    size_t wave;
    bool onPlatform;
    static immutable uint[6] waves = [30116, 30117, 30118, 30119, 30118, 30117];

    mixin(encounterOf!"NaxxEncounter.heigan");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        groundSteps(me);
        steps.after(Step.wave, 15.seconds);
        steps.after(Step.taunt, between(me, 25_000, 90_000));
    }

    private void groundSteps(ref CreatureContext me)
    {
        steps.after(Step.fever, between(me, 15_000, 20_000));
        steps.after(Step.burn, 5.seconds);
        steps.after(Step.platformPhase, 90.seconds);
    }

    void reset(ref CreatureContext me)
    {
        wave = 0;
        onPlatform = false;
        me.rooted(false);
        me.melee(true);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.wave:
            if (const controller = me.creatureNearby(17293, 100))
                me.castAs(controller, waves[wave], controller, true);
            wave = (wave + 1) % waves.length;
            steps.after(step, onPlatform ? 3.seconds : 10.seconds);
            break;
        case Step.fever:
            steps.after(step, me.castSelf(decrepitFever) == ActionResult.ok ? between(me, 20_000, 25_000) : retry);
            break;
        case Step.burn:
            steps.after(step, me.castSelf(manaBurn) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.platformPhase:
            onPlatform = true;
            wave = 0;
            steps.after(Step.wave, 6.seconds);
            steps.cancel(Step.fever);
            steps.cancel(Step.burn);
            me.teleport(platform);
            me.sayText(sayChanneling);
            me.melee(false);
            me.rooted(true);
            me.castSelf(plagueCloud);
            steps.after(Step.groundPhase, 45.seconds);
            break;
        case Step.groundPhase:
            onPlatform = false;
            wave = 0;
            steps.after(Step.wave, 10.seconds);
            me.interrupt();
            me.removeAura(me.self, plagueCloud);
            me.rooted(false);
            me.melee(true);
            if (const target = me.selectTarget(Pick.nearest))
                me.attack(target);
            groundSteps(me);
            break;
        case Step.taunt:
            me.sayText(taunts[me.random(4)]);
            steps.after(step, between(me, 25_000, 90_000));
            break;
        }
    }
}

/// A Diseased (or Rotting) Maggot: does not follow into Heigan's room.
@creature("npc_diseased_maggot")
struct DiseasedMaggot
{
    enum Step : ubyte { check }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.every(Step.check, 3.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        EntityRef[1] trigger;
        if (me.creaturesNearby(npcWorldTrigger, 45, trigger[]))
            me.evade();
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// Loatheb: his poison aura, Corrupted Mind, Inevitable Doom (faster after five minutes), spores every
/// thirteen seconds, and his own curses removed.
@creature("boss_loatheb")
struct Loatheb
{
    enum : uint { corruptedMind = 29_201, poisonAura = 29_865, inevitableDoom = 29_204, removeCurse = 30_281 }
    enum Step : ubyte { mind, doom, spore, curse, softEnrage }
    Schedule!Step steps;
    bool enraged;

    mixin(encounterOf!"NaxxEncounter.loatheb");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!me.hasAura(me.self, poisonAura))
            me.castSelf(poisonAura, true);
        steps.after(Step.mind, 5.seconds);
        steps.after(Step.doom, 2 * 60.seconds);
        steps.after(Step.spore, 13.seconds);
        steps.after(Step.curse, 2.seconds);
        steps.after(Step.softEnrage, 5 * 60.seconds);
    }

    void reset(ref CreatureContext me)
    {
        enraged = false;
        EntityRef[16] spores;
        foreach (s; spores[0 .. me.creaturesNearby(npcSpore, 100, spores[])])
            me.despawn(s);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.mind:
            steps.after(step, me.castSelf(corruptedMind) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.doom:
            steps.after(step, me.castSelf(inevitableDoom) == ActionResult.ok ? (enraged ? 15.seconds : 30.seconds) : retry);
            break;
        case Step.spore:
            import std.math : cos, sin, PI;

            const at = me.location;
            const angle = me.random(360) * PI / 180;
            me.summon(npcSpore, Location(at.x + 15 * cos(angle), at.y + 15 * sin(angle), at.z));
            steps.after(step, 13.seconds);
            break;
        case Step.curse:
            steps.after(step, me.castSelf(removeCurse) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.softEnrage:
            enraged = true;
            steps.after(Step.doom, 15.seconds);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// The Military Quarter
// ---------------------------------------------------------------------------

/// Instructor Razuvious: Unbalancing Strike, Disrupting Shout (his understudies, mind-controlled in the
/// original, are not here); Hopeless on his death.
@creature("boss_razuvious")
struct Razuvious
{
    static immutable uint[4] aggroLines = [13_075, 13_076, 13_078, 13_080];
    enum uint slayLine = 13_081, deathLine = 13_079;
    enum : uint { unbalancingStrike = 26_613, disruptingShout = 29_107, hopeless = 29_125 }
    enum Step : ubyte { strike, shout }
    Schedule!Step steps;

    mixin(encounterOf!"NaxxEncounter.razuvious");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.strike, 30.seconds);
        steps.after(Step.shout, 15.seconds);
    }

    void died(ref CreatureContext me)
    {
        me.castSelf(hopeless, true);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.strike:
            steps.after(step, me.castSpell(unbalancingStrike) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.shout:
            steps.after(step, me.castSelf(disruptingShout) == ActionResult.ok ? 25.seconds : retry);
            break;
        }
    }
}

/**
 * Gothik the Harvester: from his balcony (untouchable) he sends unrelenting trainees, death knights and
 * riders against the living side for four and a half minutes, then comes down and fights with Shadow
 * Bolt and Harvest Soul, teleporting between the two sides until he has done so four times or is below
 * 30%.
 */
@creature("boss_gothik")
struct Gothik
{
    static immutable uint[4] speech = [13_030, 13_031, 13_032, 13_033];
    enum uint slayLine = 13_027, deathLine = 13_026, sayTeleport = 13_028;
    enum : uint { harvestSoul = 28_679, shadowBolt = 29_317, immuneAll = 29_230 }
    static immutable Location[2] sides = [Location(2692f, -3399.27f, 267.686f, 4.70454f),
        Location(2692f, -3321.86f, 267.686f, 2.19126f)];

    enum Step : ubyte { speech, trainee, knight, rider, groundPhase, bolt, harvest, teleport }
    Schedule!Step steps;
    ubyte speechStep, teleports, side;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(immuneAll, true);
        me.unitFlags(UnitFlag.uninteractible, true);
        me.rooted(true);
        me.melee(false);
        speechStep = teleports = side = 0;
        steps.after(Step.speech, 1.seconds);
        steps.after(Step.trainee, 24.seconds);
        steps.after(Step.knight, 74.seconds);
        steps.after(Step.rider, 134.seconds);
        steps.after(Step.groundPhase, 274.seconds);
        me.signalDungeon(NaxxEncounter.gothik, EncounterState.inProgress);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.sayText(deathLine);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.sayText(slayLine);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.removeAura(me.self, immuneAll);
        me.unitFlags(UnitFlag.uninteractible, false);
        me.rooted(false);
        me.melee(true);
        me.signalDungeon(NaxxEncounter.gothik, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (e.after <= 30 && steps.pending(Step.teleport))
            steps.after(Step.teleport, 0.msecs); // open after the hit is applied
    }

    private void openGate(ref CreatureContext me)
    {
        steps.cancel(Step.teleport);
        me.signalDungeon(NaxxEncounter.gothik, EncounterState.special);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.speech:
            if (speechStep < speech.length)
            {
                me.sayText(speech[speechStep++]);
                steps.after(step, 4.seconds);
            }
            break;
        case Step.trainee:
            steps.after(step, 20.seconds);
            me.signalDungeon(NaxxSignal.gothikWave, npcUnrelentingTrainee);
            break;
        case Step.knight:
            steps.after(step, 25.seconds);
            me.signalDungeon(NaxxSignal.gothikWave, npcUnrelentingKnight);
            break;
        case Step.rider:
            steps.after(step, 30.seconds);
            me.signalDungeon(NaxxSignal.gothikWave, npcUnrelentingRider);
            break;
        case Step.groundPhase:
            foreach (s; [Step.trainee, Step.knight, Step.rider])
                steps.cancel(s);
            me.sayText(sayTeleport);
            me.removeAura(me.self, immuneAll);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.rooted(false);
            me.melee(true);
            me.teleport(sides[side]);
            me.resetThreat();
            if (const target = me.selectTarget(Pick.nearest))
                me.attack(target);
            steps.after(Step.bolt, 2.seconds);
            steps.after(Step.harvest, 2.seconds);
            steps.after(Step.teleport, 20.seconds);
            me.signalDungeon(NaxxSignal.saveGothik);
            break;
        case Step.bolt:
            steps.after(step, me.castSpell(shadowBolt) == ActionResult.ok ? between(me, 1000, 2000) : retry);
            break;
        case Step.harvest:
            steps.after(step, me.castSelf(harvestSoul) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.teleport:
            if (me.healthPercent <= 30)
            {
                openGate(me);
                break;
            }
            ++teleports;
            side ^= 1;
            me.teleport(sides[side]);
            me.resetThreat();
            if (const target = me.selectTarget(Pick.nearest))
                me.attack(target);
            if (teleports == 4)
                openGate(me);
            else
            {
                steps.after(step, 20.seconds);
                me.signalDungeon(NaxxSignal.saveGothik);
            }
            break;
        }
    }
}

/**
 * What the Four Horsemen share: their mark every twelve seconds, their special every twelve, shield walls
 * at 50% and 20%; each that dies leaves its spirit; the four dead are the encounter.
 */
private mixin template Horseman(uint mark, uint special, uint spirit, uint aggro, uint specialLine, uint slay,
    uint death)
{
    enum uint shieldWall = 29_061;
    enum Step : ubyte { mark, special, enrage }
    Schedule!Step steps;
    ubyte walls;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(NaxxEncounter.fourHorsemen, EncounterState.inProgress);
        me.sayText(aggro);
        steps.after(Step.mark, 20.seconds);
        steps.after(Step.special, 15.seconds);
        steps.after(Step.enrage, 20 * 60.seconds);
        // His fellows join in.
        foreach (other; [npcMograine, npcZeliek, npcThane, npcBlaumeux])
        {
            EntityRef[1] h;
            if (other != me.self.entry && me.creaturesNearby(other, 200, h[]))
                me.attack(h[0], e.enemy);
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if ((walls == 0 && e.after <= 50) || (walls == 1 && e.after <= 20))
            if (me.castSelf(shieldWall, true) == ActionResult.ok)
                ++walls;
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.sayText(slay);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.mark:
            steps.after(step, me.castSelf(mark) == ActionResult.ok ? 12.seconds : retry);
            break;
        case Step.special:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            if (target && me.castSpell(special, target) == ActionResult.ok)
            {
                if (me.random(10) == 0)
                    me.sayText(specialLine);
                steps.after(step, 12.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.enrage:
            me.castSelf(26_662, true); // berserk
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        walls = 0;
        me.signalDungeon(NaxxEncounter.fourHorsemen, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.sayText(death);
        me.castSelf(spirit, true);
        me.signalDungeon(NaxxEncounter.fourHorsemen, EncounterState.done);
    }
}

/// Lady Blaumeux: Mark of Blaumeux, Void Zone.
@creature("boss_lady_blaumeux")
struct LadyBlaumeux
{
    mixin Horseman!(28_833, 28_863, 28_931, 13_010, 13_013, 13_012, 13_011) horseman;
    alias steps = horseman.steps;
    alias on = horseman.on;
}

/// Highlord Mograine: Mark of Mograine, Righteous Fire.
@creature("boss_alexandros_mograine")
struct HighlordMograine
{
    mixin Horseman!(28_834, 28_882, 28_928, 13_051, 13_057, 13_055, 13_054) horseman;
    alias steps = horseman.steps;
    alias on = horseman.on;
}

/// Thane Korth'azz: Mark of Korth'azz, Meteor.
@creature("boss_thane_korthazz")
struct ThaneKorthazz
{
    mixin Horseman!(28_832, 28_884, 28_932, 13_034, 13_037, 13_036, 13_035) horseman;
    alias steps = horseman.steps;
    alias on = horseman.on;
}

/// Sir Zeliek: Mark of Zeliek, Holy Wrath.
@creature("boss_sir_zeliek")
struct SirZeliek
{
    mixin Horseman!(28_835, 28_883, 28_934, 13_097, 13_100, 13_099, 13_098) horseman;
    alias steps = horseman.steps;
    alias on = horseman.on;
}

// ---------------------------------------------------------------------------
// The Construct Quarter
// ---------------------------------------------------------------------------

/// Patchwerk: Hateful Strike on the healthiest of those in his reach among his most hated, a frenzy at
/// 5%, berserk after seven minutes (and slime bolts at whoever then).
@creature("boss_patchwerk")
struct Patchwerk
{
    static immutable uint[2] aggroLines = [13_068, 13_069];
    enum uint slayLine = 13_071, deathLine = 13_070, emoteBerserk = 4428, emoteEnraged = 2384;
    enum : uint { hatefulStrike = 28_308, enrage = 28_131, berserk = 26_662, slimebolt = 32_309 }
    enum Step : ubyte { strike, berserk, slimebolt }
    Schedule!Step steps;
    bool enraged, berserked;

    mixin(encounterOf!"NaxxEncounter.patchwerk");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.strike, 1200.msecs);
        steps.after(Step.berserk, 7 * 60.seconds);
    }

    void reset(ref CreatureContext me)
    {
        enraged = berserked = false;
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.after < 5 && me.castSelf(enrage) == ActionResult.ok)
        {
            enraged = true;
            me.sayText(emoteEnraged);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.strike:
            // Limit the threat ranks before checking melee range. Prefer a secondary
            // target and keep the active tank as the fallback if no one else qualifies.
            const tank = me.victim;
            EntityRef best;
            uint bestHealth;
            foreach (uint i; 0 .. 4)
            {
                const t = me.selectTarget(Pick.topThreat, PickFilter.player, i);
                if (!t)
                    break;
                if (t == tank || !me.inMeleeReach(t))
                    continue;
                const hp = me.healthOf(t);
                if (hp > bestHealth)
                {
                    best = t;
                    bestHealth = hp;
                }
            }
            if (!best && me.inMeleeReach(tank))
                best = tank;
            if (best)
                me.castSpell(hatefulStrike, best);
            steps.after(step, 1200.msecs);
            break;
        case Step.berserk:
            if (me.castSelf(berserk) == ActionResult.ok)
            {
                berserked = true;
                me.sayText(emoteBerserk);
                steps.after(Step.slimebolt, 2.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.slimebolt:
            me.castSpell(slimebolt);
            steps.after(step, 2.seconds);
            break;
        }
    }
}

/// Grobbulus: Mutating Injection (a poison cloud where its bearer stands ten seconds on), Slime Spray (a
/// fallout slime from it), poison clouds of his own, slime streams at whoever when nobody is in his reach,
/// berserk after twelve minutes.
@creature("boss_grobbulus")
struct Grobbulus
{
    enum : uint { slimeStream = 28_137, mutatingInjection = 28_169, poisonCloud = 28_240, slimeSpray = 28_157,
        berserk = 26_662 }
    enum Step : ubyte { injection, cloudAtVictim, spray, ownCloud, berserk, meleeCheck }
    Schedule!(Step, 10) steps;
    EntityRef injected;

    mixin(encounterOf!"NaxxEncounter.grobbulus");

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.injection, 12.seconds);
        steps.after(Step.spray, between(me, 20_000, 30_000));
        steps.after(Step.ownCloud, 15.seconds);
        steps.after(Step.berserk, 12 * 60.seconds);
        steps.after(Step.meleeCheck, 5.seconds);
    }

    void reset(ref CreatureContext me)
    {
        EntityRef[24] adds;
        foreach (entry; [npcFalloutSlime, npcGrobbulusCloud])
            foreach (a; adds[0 .. me.creaturesNearby(entry, 150, adds[])])
                me.despawn(a);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.injection:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            if (target && me.castSpell(mutatingInjection, target) == ActionResult.ok)
            {
                injected = target;
                steps.after(Step.cloudAtVictim, 10.seconds);
            }
            // Faster as he weakens.
            steps.after(step, (6000 + me.healthPercent * 70).msecs);
            break;
        case Step.cloudAtVictim:
            if (injected && me.alive(injected))
                me.summon(npcGrobbulusCloud, where(me, injected), 60_000);
            injected = EntityRef.init;
            break;
        case Step.spray:
            if (me.castSelf(slimeSpray) == ActionResult.ok)
            {
                if (const v = me.victim)
                    me.summon(npcFalloutSlime, where(me, v), 0, me.selectTarget(Pick.random, PickFilter.player));
                steps.after(step, between(me, 30_000, 33_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.ownCloud:
            me.summon(npcGrobbulusCloud, me.location, 60_000);
            steps.after(step, 15.seconds);
            break;
        case Step.berserk:
            if (me.castSelf(berserk) != ActionResult.ok)
                steps.after(step, retry);
            break;
        case Step.meleeCheck:
            if (!me.selectTarget(Pick.topThreat, PickFilter.inMelee))
                me.castSelf(slimeStream, true);
            steps.after(step, 5.seconds);
            break;
        }
    }
}

/// Decimate leaves living players, their controlled units and Zombie Chow at five percent of maximum health.
/// A target already below the threshold takes no damage.
@spell("spell_gluth_decimate")
struct GluthDecimate
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect || (e.target.entry != npcZombieChow && !it.playerControlled(e.target)))
            return;
        const current = it.health(e.target);
        const maximum = it.maxHealth(e.target);
        const floor = maximum >= 20 ? maximum / 20 : 1;
        if (current > floor)
            it.castCustom(e.caster, 28_375, e.target, [cast(int)(current - floor), 0, 0]);
    }
}

/// Gluth uses a 105-second approximation until a reference pull establishes the Decimate trigger.
/// Mortal Wound, Terrifying Roar, frenzies and Decimate (his zombie chows brought
/// low, and they crawl to him), eating the chows that reach him; zombie chows come from the doors every
/// six seconds; berserk after six and a half minutes.
@creature("boss_gluth")
struct Gluth
{
    enum uint emoteEnraged = 2384, emoteDevours = 12_242;
    enum : uint { doubleAttack = 19_818, mortalWound = 25_646, decimate = 28_374, frenzy = 28_371,
        berserk = 26_662, terrifyingRoar = 29_685 }
    enum Step : ubyte { chow, mortalWound, decimate, frenzy, roar, berserk, eat }
    Schedule!(Step, 10) steps;

    mixin(encounterOf!"NaxxEncounter.gluth");

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
    }

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.chow, 6.seconds);
        steps.after(Step.mortalWound, 10.seconds);
        steps.after(Step.decimate, 105.seconds);
        steps.after(Step.frenzy, 10.seconds);
        steps.after(Step.roar, 20.seconds);
        steps.after(Step.berserk, 390.seconds);
        steps.after(Step.eat, 3.seconds);
    }

    void reset(ref CreatureContext me)
    {
        EntityRef[40] chows;
        foreach (c; chows[0 .. me.creaturesNearby(npcZombieChow, 200, chows[])])
            me.despawn(c);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.chow:
            // A zombie chow from one of the doors.
            EntityRef[12] doorsNear;
            const n = me.creaturesNearby(npcWorldTrigger, 120, doorsNear[]);
            if (n)
                me.summon(npcZombieChow, where(me, doorsNear[me.random(cast(uint) n)]), 0,
                    me.selectTarget(Pick.random, PickFilter.player));
            steps.after(step, 6.seconds);
            break;
        case Step.mortalWound:
            steps.after(step, me.castSpell(mortalWound) == ActionResult.ok ? 10.seconds : retry);
            break;
        case Step.decimate:
            if (me.castSelf(decimate) == ActionResult.ok)
            {
                // Every chow brought low; they crawl to him.
                EntityRef[40] chows;
                foreach (c; chows[0 .. me.creaturesNearby(npcZombieChow, 200, chows[])])
                {
                    me.moveCreature(c, me.location, 0);
                }
                steps.after(step, 105.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.frenzy:
            if (me.castSelf(frenzy) == ActionResult.ok)
            {
                me.sayText(emoteEnraged);
                steps.after(step, 10.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.roar:
            steps.after(step, me.castSelf(terrifyingRoar) == ActionResult.ok ? 20.seconds : retry);
            break;
        case Step.berserk:
            if (me.castSelf(berserk) != ActionResult.ok)
                steps.after(step, retry);
            break;
        case Step.eat:
            // Chows that reach him are eaten: five percent of his health each.
            EntityRef[8] near;
            foreach (c; near[0 .. me.creaturesNearby(npcZombieChow, 6, near[])])
            {
                me.sayText(emoteDevours);
                me.despawn(c);
                const hp = me.healthPercent + 5;
                me.setHealthPercent(hp > 100 ? 100 : hp);
            }
            steps.after(step, 3.seconds);
            break;
        }
    }
}

/**
 * What Stalagg and Feugen share: each falls (not dead) when slain; if the other falls within five seconds
 * both die and Thaddius wakes, else the fallen one rises again.
 */
private mixin template ThaddiusAdd(uint other, uint warstompOrPull, uint aggro, uint slay, uint death)
{
    enum uint powerSurgeOrStatic = warstompOrPull;
    enum Step : ubyte { ability, rise, resumeChase }
    Schedule!Step steps;
    bool down;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(NaxxEncounter.thaddius, EncounterState.inProgress);
        me.sayText(aggro);
        steps.after(Step.ability, between(me, 10_000, 15_000));
        EntityRef[1] o;
        if (me.creaturesNearby(other, 200, o[]))
            me.attack(o[0], e.enemy);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.sayText(slay);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (down || e.after != 0)
            return;
        down = true;
        me.standState(StandState.dead);
        me.unitFlags(UnitFlag.uninteractible, true);
        me.melee(false);
        me.combatMovement(false);
        steps.clear();
        EntityRef[1] o;
        if (me.creaturesNearby(other, 200, o[]))
            me.signal(o[0], NaxxSignal.addFell);
        steps.after(Step.rise, 5.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == NaxxSignal.magneticPull && !down)
        {
            if (const victim = me.victim)
                me.modifyThreat(victim, -100);
            if (e.value)
                me.addThreat(EntityRef(cast(uint) e.value), 0);
            me.combatMovement(false);
            steps.after(Step.resumeChase, 3.seconds);
            return;
        }
        if (e.id == NaxxSignal.addsDone && down)
        {
            // The other fell within our window and died: so do we (else we rose again beside Thaddius).
            steps.clear();
            me.sayText(death);
            me.deathPrevention(false);
            me.die();
            return;
        }
        if (e.id != NaxxSignal.addFell || !down)
            return;
        // Both down within the window: both die, and Thaddius wakes.
        steps.clear();
        me.signalDungeon(NaxxEncounter.thaddius, EncounterState.special);
        EntityRef[1] o;
        if (me.creaturesNearby(other, 200, o[]))
            me.signal(o[0], NaxxSignal.addsDone);
        me.sayText(death);
        me.deathPrevention(false);
        me.die();
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.ability:
            steps.after(step, me.castSelf(powerSurgeOrStatic) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.rise:
            // Alone too long: it rises again.
            down = false;
            me.standState(StandState.stand);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.melee(true);
            me.combatMovement(true);
            me.setHealthPercent(100);
            steps.after(Step.ability, between(me, 10_000, 15_000));
            if (const t = me.selectTarget(Pick.nearest))
                me.attack(t);
            break;
        case Step.resumeChase:
            if (!me.inMeleeReach(me.victim) && me.threatOf(me.victim) == 0)
                if (const nearby = me.selectTarget(Pick.nearest, PickFilter.player | PickFilter.inMelee))
                    me.attack(nearby);
            me.combatMovement(true);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        down = false;
        me.standState(StandState.stand);
        me.unitFlags(UnitFlag.uninteractible, false);
        me.melee(true);
        me.combatMovement(true);
        me.signalDungeon(NaxxEncounter.thaddius, EncounterState.failed);
    }
}

/// Stalagg: Power Surge.
@creature("boss_stalagg")
struct Stalagg
{
    mixin ThaddiusAdd!(npcFeugen, 28_134, 13_083, 13_085, 13_084) add;
    alias steps = add.steps;
    alias on = add.on;
}

/// Feugen: Static Field.
@creature("boss_feugen")
struct Feugen
{
    mixin ThaddiusAdd!(npcStalagg, 28_135, 13_023, 13_025, 13_024) add;
    alias steps = add.steps;
    alias on = add.on;
}

/// Thaddius: wakes when Stalagg and Feugen are dead; Polarity Shift, Chain Lightning, Ball Lightning at
/// whoever when nobody is in his reach; berserk after six minutes.
@creature("boss_thaddius")
struct Thaddius
{
    static immutable uint[3] aggroLines = [13_086, 13_087, 13_088];
    enum uint slayLine = 13_096, deathLine = 13_089, sayElect = 13_090;
    enum : uint { spawn = 28_160, ballLightning = 28_299, chainLightning = 28_167, polarityShift = 28_089,
        berserk = 27_680 }
    enum Step : ubyte { wake, polarity, chain, ball, berserk }
    Schedule!Step steps;
    bool awake;

    mixin(encounterOf!"NaxxEncounter.thaddius");

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (me.askDungeon(NaxxEncounter.thaddius) != EncounterState.special)
        {
            me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer, true);
            me.reactState(Reaction.passive);
            if (!me.hasAura(me.self, spawn))
                me.castSelf(spawn, true); // waiting, stunned, till his coils' masters fall
        }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == NaxxSignal.addsDone && !awake)
            steps.after(Step.wake, 10.seconds);
    }

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.polarity, 15.seconds);
        steps.after(Step.chain, between(me, 10_000, 20_000));
        steps.after(Step.ball, 1.seconds);
        steps.after(Step.berserk, 6 * 60.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.wake:
            // Thadius Spawn (28160) is the stun he waits in (ScriptDev casts it as he spawns and takes it off as
            // the coils' lightning wakes him, with its visual, 28136, left out here); cast here, it stunned him for
            // good.
            awake = true;
            me.removeAura(me.self, spawn);
            me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer, false);
            me.reactState(Reaction.aggressive);
            me.zoneCombat();
            break;
        case Step.polarity:
            if (me.castSelf(polarityShift) == ActionResult.ok)
            {
                me.sayText(sayElect);
                steps.after(step, 30.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.chain:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(chainLightning, target) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.ball:
            if (!me.selectTarget(Pick.topThreat, PickFilter.inMelee))
                if (const target = me.selectTarget(Pick.random, PickFilter.player))
                    me.castSpell(ballLightning, target);
            steps.after(step, 1.seconds);
            break;
        case Step.berserk:
            if (me.castSelf(berserk) != ActionResult.ok)
                steps.after(step, retry);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// The Frostwyrm Lair
// ---------------------------------------------------------------------------

/**
 * Sapphiron: his frost aura, Cleave, Tail Sweep, Life Drain, blizzards; above a tenth of his health he
 * returns to the center, freezes players and breathes frost across the room before landing.
 *
 * The copy saves him while he fights (`Naxxramas.setSapphiron`); he asks it to (`NaxxSignal.saveSapphiron`) as each
 * timer or phase moves on, after the change, so that a worker's crash resumes him where he was: his breath begun
 * is cast on (`Creature.saveState` keeps the cast), and lands once.
 */
@creature("boss_sapphiron")
struct Sapphiron
{
    enum uint emoteBreath = 7213, emoteEnraged = 2384;
    enum : uint
    {
        doubleAttack = 19_818,
        frostAura = 28_529,
        berserk = 26_662,
        cleave = 19_983,
        tailSweep = 15_847,
        lifeDrain = 28_542,
        summonBlizzard = 28_560,
        dragonHover = 18_430,
        icebolt = 28_522,
        frostBreathDummy = 30_101, frostBreath = 28_524, iceboltImmunity = 31_800,
    }
    enum Step : ubyte { berserk, air, cleave, tail, drain, blizzard, icebolt, land, ground }
    Schedule!(Step, 12) steps;
    bool inAir;
    ubyte icebolts;
    EntityRef[] frozen;
    EntityRef[] splashed;
    static immutable flight = Location(3522.386f, -5236.784f, 137.709f);

    mixin(encounterOf!"NaxxEncounter.sapphiron");

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, doubleAttack))
            me.castSelf(doubleAttack, true);
        // Born, he takes the raid in his lair at once; come again after a wipe and a restart, he waits to be pulled.
        if (me.askDungeon(NaxxEncounter.sapphiron) == EncounterState.special)
            me.zoneCombat();
    }

    void on(ref CreatureContext me, const ref CreatureCastFinished e)
    {
        if (e.spell == frostBreath)
            me.signalDungeon(NaxxSignal.saveSapphiron); // landed: a crash from now on must not breathe it again
    }

    /// `step` again after `interval` (one whose cast failed: soon), the change saved.
    private void again(ref CreatureContext me, Step step, bool casted, Duration interval)
    {
        steps.after(step, casted ? interval : retry);
        if (casted)
            me.signalDungeon(NaxxSignal.saveSapphiron);
    }

    void engaged(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(frostAura, true);
        steps.after(Step.berserk, 15 * 60.seconds);
        steps.after(Step.air, 46.seconds);
        groundSteps(me);
        me.signalDungeon(NaxxSignal.saveSapphiron); // his timers with the fight the copy saved as it began
    }

    private void groundSteps(ref CreatureContext me)
    {
        steps.after(Step.cleave, 5.seconds);
        steps.after(Step.tail, 12.seconds);
        steps.after(Step.drain, 11.seconds);
        steps.after(Step.blizzard, 15.seconds);
    }

    private void clearIce(ref CreatureContext me)
    {
        foreach (target; frozen)
        {
            me.removeAura(target, icebolt);
            me.removeAura(target, iceboltImmunity);
        }
        frozen = null;
        splashed = null;
        me.signalDungeon(NaxxSignal.clearIceBlocks);
    }

    void died(ref CreatureContext me) { clearIce(me); }

    /// An Icebolt at one of the raid not frozen and not beside a block; whether it froze one (the copy saved him).
    private bool freeze(ref CreatureContext me)
    {
        import std.algorithm.searching : canFind;
        EntityRef[40] raid;
        const count = me.threatList(raid[]);
        EntityRef[] eligible;
        foreach (who; raid[0 .. count])
            if (who.isPlayer && me.alive(who) && !frozen.canFind(who) && !splashed.canFind(who))
                eligible ~= who;
        if (!eligible.length)
            return false;
        const target = eligible[me.random(cast(uint) eligible.length)];
        if (me.castSpell(icebolt, target, true) != ActionResult.ok || !me.hasAura(target, icebolt))
            return false;
        frozen ~= target;
        me.castAs(target, iceboltImmunity, target, true);
        Location block;
        if (me.locationOf(target, block))
            foreach (who; raid[0 .. count])
            {
                Location at;
                if (who.isPlayer && me.locationOf(who, at) && (at.x - block.x) ^^ 2
                    + (at.y - block.y) ^^ 2 + (at.z - block.z) ^^ 2 <= 100 && !splashed.canFind(who))
                    splashed ~= who;
            }
        // Last: the copy makes the block and saves it with him, as he is now.
        me.signalDungeon(NaxxSignal.freezePlayer, cast(int) target.guid);
        return true;
    }

    void reset(ref CreatureContext me)
    {
        clearIce(me);
        inAir = false;
        me.flying(false);
        me.melee(true);
        me.combatMovement(true);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.berserk:
            if (me.castSelf(berserk) == ActionResult.ok)
            {
                me.sayText(emoteEnraged);
                me.signalDungeon(NaxxSignal.saveSapphiron);
            }
            else
                steps.after(step, retry);
            break;
        case Step.air:
            if (me.healthPercent <= 10)
                break;
            inAir = true;
            foreach (s; [Step.cleave, Step.tail, Step.drain, Step.blizzard])
                steps.cancel(s);
            me.melee(false);
            me.combatMovement(false);
            me.emote(254); // EMOTE_ONESHOT_LIFTOFF
            me.teleport(flight);
            me.flying(true);
            me.castSelf(dragonHover, true);
            icebolts = 0;
            steps.after(Step.icebolt, 8.seconds);
            me.signalDungeon(NaxxSignal.saveSapphiron);
            break;
        case Step.icebolt:
            if (icebolts < 5)
            {
                ++icebolts;
                steps.after(step, 3.seconds);
                if (!freeze(me)) // last: it has the copy save him
                    me.signalDungeon(NaxxSignal.saveSapphiron); // nobody to freeze: his count moved on
            }
            else
            {
                me.sayText(emoteBreath);
                me.castSelf(frostBreathDummy, true);
                steps.after(Step.land, 8.seconds);
                me.castSelf(frostBreath);
                me.signalDungeon(NaxxSignal.saveSapphiron); // his breath begun: a crash resumes its cast
            }
            break;
        case Step.land:
            clearIce(me);
            me.removeAura(me.self, dragonHover);
            me.emote(293); // EMOTE_ONESHOT_LAND
            me.flying(false);
            steps.after(Step.ground, 2.seconds);
            me.signalDungeon(NaxxSignal.saveSapphiron);
            break;
        case Step.ground:
            inAir = false;
            me.melee(true);
            me.combatMovement(true);
            if (const t = me.selectTarget(Pick.topThreat))
                me.attack(t);
            groundSteps(me);
            steps.after(Step.air, 67.seconds);
            me.signalDungeon(NaxxSignal.saveSapphiron);
            break;
        case Step.cleave:
            const cleaved = me.castSpell(cleave) == ActionResult.ok;
            again(me, step, cleaved, cleaved ? between(me, 5000, 10_000) : retry);
            break;
        case Step.tail:
            const swept = me.castSelf(tailSweep) == ActionResult.ok;
            again(me, step, swept, swept ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.drain:
            again(me, step, me.castSelf(lifeDrain) == ActionResult.ok, 24.seconds);
            break;
        case Step.blizzard:
            if (const target = me.selectTarget(Pick.random, PickFilter.player))
                me.castSpell(summonBlizzard, target, true);
            again(me, step, true, 20.seconds);
            break;
        }
    }
}

/**
 * Kel'Thuzad: summons the dead from his alcoves for five minutes while he channels; then fights with
 * Frostbolt, Frost Bolt Nova, Mana Detonation, Shadow Fissure and Frost Blast; below 40% the Lich King
 * sends him Guardians of Icecrown. His Chains turn raiders against their allies, and he breaks
 * the shackles when more than three of them are shackled (the copy counts them).
 */
@spell("spell_chains_kel_thuzad")
struct ChainsOfKelthuzad
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect == 0 && e.caster.entry == npcKelthuzad)
            it.signal(e.caster, NaxxSignal.chains);
    }
}

@creature("boss_kelthuzad")
struct Kelthuzad
{
    enum uint saySummonMinions = 12_999, sayRequestAid = 12_998, sayAnswerRequest = 12_994, sayFrostBlast = 13_020,
        deathLine = 13_019;
    static immutable uint[3] aggroLines = [12_995, 12_996, 12_997];
    enum uint slayLine = 13_021;
    enum : uint
    {
        channelVisual = 29_422,
        frostBolt = 28_478,
        frostBoltNova = 28_479,
        manaDetonation = 27_819,
        shadowFissure = 27_810,
        frostBlast = 27_808,
        guardianInit = 29_898,     /// the copy starts counting shackled guardians (event 10536)
        clearAllShackles = 29_910,
    }
    enum uint sayShackles = 13_492;

    enum Step : ubyte { soldiers, abominations, weavers, phase2, frostBolt, nova, detonation, fissure, blast,
        guardians, lichKing, chains }
    Schedule!(Step, 13) steps;
    ubyte phase, guardiansSent;
    EntityRef[64] minions;
    EntityRef[] chained;

    private void releaseRaid(ref CreatureContext me)
    {
        foreach (who; chained)
        {
            me.removeAura(who, 28410);
            me.removeAura(who, 28409);
        }
        chained = null;
    }

    private void chainRaid(ref CreatureContext me)
    {
        const tank = me.victim;
        if (!tank.isPlayer || !me.alive(tank) || me.distanceTo(tank) > 100)
            return;
        EntityRef[40] threat;
        EntityRef[] others;
        foreach (who; threat[0 .. me.threatList(threat[])])
            if (who != tank && who.isPlayer && me.alive(who) && me.distanceTo(who) <= 100)
                others ~= who;
        if (others.length <= 4)
            return;
        releaseRaid(me);
        EntityRef[5] chosen;
        chosen[0] = tank;
        foreach (ref who; chosen[1 .. $])
        {
            const i = me.random(cast(uint) others.length);
            who = others[i];
            others[i] = others[$ - 1];
            others.length--;
        }
        me.sayText(13017 + me.random(2));
        foreach (who; chosen)
            if (me.castSpell(28410, who, true) == ActionResult.ok && me.hasAura(who, 28410))
            {
                chained ~= who;
                me.castAs(who, 28409, who, true);
                me.modifyThreat(who, -100);
            }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == NaxxSignal.chains)
            return chainRaid(me);
        if (e.id == NaxxSignal.clearShackles)
        {
            me.sayText(sayShackles);
            me.castSelf(clearAllShackles, true);
            return;
        }
        if (e.id != NaxxSignal.startKt || phase)
            return;
        // Phase one: he channels, untouchable, while his minions come from the alcoves.
        phase = 1;
        me.sayText(saySummonMinions);
        me.castSelf(channelVisual, true);
        me.unitFlags(UnitFlag.uninteractible, true);
        me.rooted(true);
        me.melee(false);
        steps.after(Step.soldiers, 5.seconds);
        steps.after(Step.abominations, 30.seconds);
        steps.after(Step.weavers, 40.seconds);
        steps.after(Step.phase2, (5 * 60 + 25).seconds);
    }

    /// A minion of `entry` from one of the alcoves, after someone.
    private void fromAlcove(ref CreatureContext me, uint entry)
    {
        EntityRef[12] alcoves;
        const n = me.creaturesNearby(npcWorldTrigger, 120, alcoves[]);
        if (!n)
            return;
        const made = me.summon(entry, where(me, alcoves[me.random(cast(uint) n)]), 0,
            me.selectTarget(Pick.random, PickFilter.player));
        foreach (ref m; minions)
            if (!m)
            {
                m = made;
                break;
            }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (phase >= 2)
            me.sayText(aggroLines[me.random(3)]);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.sayText(slayLine);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (phase == 2 && e.after < 40)
        {
            phase = 3;
            me.sayText(sayRequestAid);
            me.castSelf(guardianInit, true);
            steps.after(Step.lichKing, 4.seconds);
            steps.after(Step.guardians, 5.seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.soldiers:
            if (phase == 1)
            {
                fromAlcove(me, npcSoldierFrozen);
                steps.after(step, 3.seconds);
            }
            break;
        case Step.abominations:
            if (phase == 1)
            {
                fromAlcove(me, npcUnstoppableAbom);
                steps.after(step, 25.seconds);
            }
            break;
        case Step.weavers:
            if (phase == 1)
            {
                fromAlcove(me, npcSoulWeaver);
                steps.after(step, 30.seconds);
            }
            break;
        case Step.phase2:
            phase = 2;
            me.interrupt();
            me.removeAura(me.self, channelVisual);
            me.unitFlags(UnitFlag.uninteractible, false);
            me.rooted(false);
            me.melee(true);
            me.zoneCombat();
            me.sayText(aggroLines[me.random(3)]);
            steps.after(Step.frostBolt, between(me, 1000, 60_000));
            steps.after(Step.chains, 60.seconds);
            steps.after(Step.nova, 15.seconds);
            steps.after(Step.detonation, 20.seconds);
            steps.after(Step.fissure, 25.seconds);
            steps.after(Step.blast, between(me, 30_000, 60_000));
            break;
        case Step.frostBolt:
            steps.after(step, me.castSpell(frostBolt) == ActionResult.ok ? between(me, 1000, 60_000) : retry);
            break;
        case Step.nova:
            steps.after(step, me.castSelf(frostBoltNova) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.detonation:
            const target = me.selectTarget(Pick.random, PickFilter.player | PickFilter.manaUser);
            steps.after(step, target && me.castSpell(manaDetonation, target) == ActionResult.ok ? 20.seconds : retry);
            break;
        case Step.fissure:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(shadowFissure, target) == ActionResult.ok ? 25.seconds : retry);
            break;
        case Step.blast:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            if (target && me.castSpell(frostBlast, target) == ActionResult.ok)
            {
                if (me.random(2))
                    me.sayText(sayFrostBlast);
                steps.after(step, between(me, 30_000, 60_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.chains:
            steps.after(step, me.castSelf(28408) == ActionResult.ok ? 60.seconds : retry);
            break;
        case Step.lichKing:
            EntityRef[1] lichKing;
            if (me.creaturesNearby(16_980, 200, lichKing[]))
                me.sayAs(lichKing[0], sayAnswerRequest);
            break;
        case Step.guardians:
            if (guardiansSent < 5)
            {
                ++guardiansSent;
                fromAlcove(me, npcGuardianIcecrown);
                steps.after(step, 10.seconds);
            }
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        releaseRaid(me);
        steps.clear();
        phase = guardiansSent = 0;
        me.removeAura(me.self, channelVisual);
        me.unitFlags(UnitFlag.uninteractible, false);
        me.rooted(false);
        me.melee(true);
        foreach (ref m; minions)
            if (m)
            {
                me.despawn(m);
                m = EntityRef.init;
            }
        me.signalDungeon(NaxxEncounter.kelthuzad, EncounterState.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        releaseRaid(me);
        steps.clear();
        me.sayText(deathLine);
        me.signalDungeon(NaxxEncounter.kelthuzad, EncounterState.done);
        foreach (ref m; minions)
            if (m)
            {
                me.despawn(m);
                m = EntityRef.init;
            }
    }
}

/// A Guardian of Icecrown: Blood Tap as it fights on; every two seconds it tells the copy whether it is
/// shackled (Guardian of Icecrown, event 10537).
@creature("npc_icecrown_guardian")
struct IcecrownGuardian
{
    enum uint guardianPassive = 29_897, bloodTap = 28_470, guardianShackle = 29_899;
    /// Shackle Undead, its three ranks.
    static immutable uint[3] shackleUndead = [9484, 9485, 10_955];
    enum Step : ubyte { tap, shackleCheck }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, guardianPassive))
            me.castSelf(guardianPassive, true);
        steps.every(Step.shackleCheck, 2.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.tap, 15.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.tap:
            steps.after(step, me.castSelf(bloodTap) == ActionResult.ok ? 15.seconds : retry);
            break;
        case Step.shackleCheck:
            foreach (rank; shackleUndead)
                if (me.hasAura(me.self, rank))
                {
                    me.castSelf(guardianShackle, true);
                    break;
                }
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

// ---------------------------------------------------------------------------
// The halls' creatures
// ---------------------------------------------------------------------------

/// A Stoneskin Gargoyle: stone (untouchable) until someone comes within 17 yards; Acid Volley; Stoneskin
/// below 30%.
@creature("npc_stoneskin_gargoyle")
struct StoneskinGargoyle
{
    enum uint stoneform = 29_154, stoneskin = 28_995, acidVolley = 29_325, noise = 13_080;
    enum Step : ubyte { volley, watch }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        stone(me);
    }

    private void stone(ref CreatureContext me)
    {
        if (me.castSelf(stoneform, true) == ActionResult.ok)
        {
            me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer, true);
            steps.every(Step.watch, 1.seconds);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.cancel(Step.watch);
        me.removeAura(me.self, stoneform);
        me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer, false);
        steps.after(Step.volley, 4.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (e.after < 30 && !me.hasAura(me.self, stoneskin))
            me.castSelf(stoneskin);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.watch:
            EntityRef[1] near;
            if (me.playersNear(17, near[]))
            {
                steps.cancel(Step.watch);
                me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer, false);
                me.attack(near[0]);
            }
            break;
        case Step.volley:
            steps.after(step, me.castSelf(acidVolley) == ActionResult.ok ? 8.seconds : retry);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        stone(me);
    }
}

/// A Living Poison: bursts when a player comes within four yards of it.
@creature("npc_living_poison")
struct LivingPoison
{
    enum uint explode = 28_433;
    enum Step : ubyte { watch }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.melee(false);
        steps.every(Step.watch, 500.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        EntityRef[1] near;
        if (me.playersNear(4, near[]))
        {
            steps.clear();
            me.castSelf(explode, true);
            me.die();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptKind, ScriptRuntime;

    class FakeNecropolis : BlackHole!InstanceHost
    {
        Signal[] signals;
        bool[ulong] opened;
        uint[] respawned;
        EntityRef[] summoned;
        uint[] castSpells;
        EntityRef[ulong] victims;
        uint[ulong] flags;
        override uint hostPlayerCount() { return 1; }
        override bool hostAlive(EntityRef who) { return cast(bool) who; }
        override EntityRef hostVictimOf(EntityRef who) { return victims.get(who.guid, EntityRef.init); }
        override uint hostUnitFlagsOf(EntityRef who) { return flags.get(who.guid, 0); }
        override size_t hostCreaturesNear(Location, uint entry, float, EntityRef[] into)
        {
            foreach (guid; victims.keys)
                if (EntityRef(guid).entry == entry && into.length)
                {
                    into[0] = EntityRef(guid);
                    return 1;
                }
            return 0;
        }
        override ActionResult hostCast(EntityRef, uint spell, EntityRef, bool)
        {
            castSpells ~= spell;
            return ActionResult.ok;
        }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override ActionResult hostDoor(EntityRef door, bool open)
        {
            opened[door.guid] = open;
            return ActionResult.ok;
        }
        override bool hostRespawnObject(uint entry, uint) { respawned ~= entry; return true; }
        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(entry) << 24) | summoned.length);
            return summoned[$ - 1];
        }
    }

    EntityRef naxxObject(uint entry) { return EntityRef(0xF110_0000_0000_0001UL | (ulong(entry) << 24)); }
}

/// One copy timer coordinates the swap. A fake-dead add and an encounter reset suppress it.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;

    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeNecropolis;
    auto copy = InstanceContext(host);
    auto h = runtime.create(ScriptKind.instance, "instance_naxxramas");
    const stalagg = EntityRef(0xF130_0000_0000_0001UL | (ulong(npcStalagg) << 24));
    const feugen = EntityRef(0xF130_0000_0000_0002UL | (ulong(npcFeugen) << 24));
    host.victims[stalagg.guid] = EntityRef(7);
    host.victims[feugen.guid] = EntityRef(8);
    runtime.raise(h, copy, Signal(stalagg, NaxxEncounter.thaddius, EncounterState.inProgress));
    runtime.tick(h, copy, 20_999);
    runtime.raise(h, copy, Signal(feugen, NaxxEncounter.thaddius, EncounterState.inProgress));
    assert(host.castSpells.length == 0);
    ByteWriter saved;
    runtime.save(h, saved);
    h = runtime.create(ScriptKind.instance, "instance_naxxramas");
    auto incoming = ByteReader(saved.data);
    assert(runtime.load(h, incoming));
    runtime.tick(h, copy, 1);
    assert(host.castSpells == [28_338, 28_339, 28_337, 28_337]);
    assert(host.signals == [Signal(stalagg, NaxxSignal.magneticPull, 8), Signal(feugen, NaxxSignal.magneticPull, 7)]);

    host.flags[feugen.guid] = UnitFlag.uninteractible;
    runtime.tick(h, copy, 21_000);
    assert(host.castSpells.length == 4, "no half swap during fake death");
    host.flags.remove(feugen.guid);
    host.victims[feugen.guid] = host.victims[stalagg.guid];
    runtime.tick(h, copy, 21_000);
    assert(host.castSpells.length == 4, "one shared tank must not receive two competing pulls");
    host.victims[feugen.guid] = EntityRef(8);
    runtime.raise(h, copy, Signal(feugen, NaxxEncounter.thaddius, EncounterState.failed));
    runtime.tick(h, copy, 21_000);
    assert(host.castSpells.length == 4, "a wipe cancels the swap");

    runtime.raise(h, copy, Signal(feugen, NaxxEncounter.thaddius, EncounterState.inProgress));
    runtime.tick(h, copy, 20_999);
    assert(host.castSpells.length == 4);
    runtime.tick(h, copy, 1);
    assert(host.castSpells.length == 8, "a new pull starts a fresh timer");
    runtime.raise(h, copy, Restored());
    runtime.tick(h, copy, 21_000);
    assert(host.castSpells.length == 12, "adds restored still fighting keep swapping tanks");
    runtime.raise(h, copy, Signal(stalagg, NaxxEncounter.thaddius, EncounterState.inProgress));
    runtime.tick(h, copy, 20_999);
    assert(host.castSpells.length == 12, "a signal during a running swap keeps its timing");
    runtime.tick(h, copy, 1);
    assert(host.castSpells.length == 16);

    // Restored with the adds idle (they came back fresh): the swap waits for the new pull's timing.
    host.victims[stalagg.guid] = host.victims[feugen.guid] = EntityRef.init;
    runtime.raise(h, copy, Restored());
    runtime.tick(h, copy, 15_000);
    host.victims[stalagg.guid] = EntityRef(7);
    host.victims[feugen.guid] = EntityRef(8);
    runtime.raise(h, copy, Signal(stalagg, NaxxEncounter.thaddius, EncounterState.inProgress));
    runtime.tick(h, copy, 20_999);
    assert(host.castSpells.length == 16, "a fresh pull after restoring restarts the swap timer");
    runtime.tick(h, copy, 1);
    assert(host.castSpells.length == 20, "a fresh pull can start after restoring");

    runtime.raise(h, copy, Signal(feugen, NaxxEncounter.thaddius, EncounterState.failed));
    runtime.raise(h, copy, Restored());
    runtime.tick(h, copy, 21_000);
    assert(host.castSpells.length == 20, "a restore after a wipe arms no swap");
}

/// Naxxramas' copy: Anub'Rekhan's door shuts while he fights and his gate opens when he dies; the
/// Horsemen are done with the fourth death (their chest and the quarter's portal appear); Thaddius wakes
/// when his two are dead; Sapphiron comes 22 seconds after his birth; the way up waits for every quarter.
unittest
{
    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto naxx = new FakeNecropolis;
    auto c = InstanceContext(naxx);
    auto h = runtime.create(ScriptKind.instance, "instance_naxxramas");
    const door = naxxObject(181_126), gate = naxxObject(181_195);
    runtime.raise(h, c, ObjectLoaded(door));
    runtime.raise(h, c, ObjectLoaded(gate));
    assert(naxx.opened[door.guid] && !naxx.opened[gate.guid]);
    runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.anubRekhan, EncounterState.inProgress));
    assert(!naxx.opened[door.guid]);
    runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.anubRekhan, EncounterState.done));
    assert(naxx.opened[door.guid] && naxx.opened[gate.guid]);

    foreach (i; 0 .. 3)
        runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.fourHorsemen, EncounterState.done));
    assert(naxx.respawned.length == 0, "three of four");
    runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.fourHorsemen, EncounterState.done));
    assert(naxx.respawned == [goChestHorsemen, 181_578]);

    const thaddius = EntityRef(0xF130_0000_0000_0002UL | (ulong(npcThaddius) << 24));
    runtime.raise(h, c, CreatureLoaded(thaddius));
    runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.thaddius, EncounterState.special));
    assert(naxx.signals[$ - 1] == Signal(thaddius, NaxxSignal.addsDone, 0));

    runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.sapphiron, EncounterState.special));
    runtime.tick(h, c, 21_000);
    assert(naxx.summoned.length == 0);
    runtime.tick(h, c, 1000);
    assert(naxx.summoned.length == 1 && naxx.summoned[0].entry == npcSapphiron);

    auto ask = InstanceContext(naxx);
    runtime.raise(h, ask, Asked(EntityRef.init, Naxxramas.askFrostwyrm));
    assert(ask.answerGiven == 0, "Maexxna, Loatheb and Thaddius live");
}

version (unittest)
{
    class FakeConstruct : BlackHole!CreatureHost
    {
        uint entry = npcStalagg;
        Signal[] dungeon, signals;
        bool dead, preventing;
        uint health = 100;
        StandState stand;
        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(entry) << 24)); }
        override void hostSignalDungeon(uint id, int value) { dungeon ~= Signal(EntityRef.init, id, value); }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override void hostDie() { dead = true; }
        override void hostDeathPrevention(bool on) { preventing = on; }
        override void hostStandState(StandState s) { stand = s; }
        override void hostSetHealthPercent(EntityRef, uint p) { health = p; }
        override size_t hostCreaturesNearby(uint e, float, EntityRef[] into)
        {
            if (into.length == 0 || (e != npcFeugen && e != npcStalagg))
                return 0;
            into[0] = EntityRef(0xF130_0000_0000_0002UL | (ulong(e) << 24));
            return 1;
        }
    }
}

/// Stalagg and Feugen: one falling alone rises again after five seconds; both falling together die, and
/// Thaddius' encounter goes on.
unittest
{
    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeConstruct;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_stalagg");
    runtime.raise(h, me, Spawned());
    assert(host.preventing);
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.raise(h, me, Damaged(EntityRef(7), 900, 3, 0));
    assert(host.stand == StandState.dead && host.signals[$ - 1].id == NaxxSignal.addFell);
    foreach (_; 0 .. 50)
        runtime.tick(h, me, 100);
    assert(host.stand == StandState.stand && host.health == 100 && !host.dead, "alone: it rose again");

    runtime.raise(h, me, Damaged(EntityRef(7), 900, 3, 0));
    runtime.raise(h, me, Signal(EntityRef.init, NaxxSignal.addFell, 0)); // Feugen fell too
    assert(host.dead && host.dungeon[$ - 1] == Signal(EntityRef.init, NaxxEncounter.thaddius, EncounterState.special));
}

/// Kel'Thuzad's guardians: counted every two seconds once he starts the count (event 10536); more than three
/// shackled (event 10537 each) and he is told to break the shackles. Gluth's Decimate is the scripts' own.
unittest
{
    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto naxx = new FakeNecropolis;
    auto c = InstanceContext(naxx);
    auto h = runtime.create(ScriptKind.instance, "instance_naxxramas");
    const kt = EntityRef(0xF130_0000_0000_0001UL | (ulong(npcKelthuzad) << 24));
    runtime.raise(h, c, CreatureLoaded(kt));
    runtime.raise(h, c, Signal(kt, NaxxEncounter.kelthuzad, EncounterState.inProgress));
    runtime.raise(h, c, EventHappened(Naxxramas.decimateEvent, EntityRef.init, EntityRef.init));
    assert(c.consumed, "Gluth does what the database script would");
    runtime.raise(h, c, EventHappened(Naxxramas.clearShacklesEvent, kt, EntityRef.init));
    foreach (_; 0 .. 3)
        runtime.raise(h, c, EventHappened(Naxxramas.guardianShackleEvent, EntityRef.init, EntityRef.init));
    runtime.tick(h, c, 2000);
    assert(naxx.signals.length == 0, "three may be shackled");
    foreach (_; 0 .. 4)
        runtime.raise(h, c, EventHappened(Naxxramas.guardianShackleEvent, EntityRef.init, EntityRef.init));
    runtime.tick(h, c, 2000);
    assert(naxx.signals == [Signal(kt, NaxxSignal.clearShackles, 0)]);
}

/// Maexxna throws up to three players to the invisible men on her walls (one each); a man wraps his player
/// five seconds later.
unittest
{
    import std.algorithm.searching : canFind;

    static class FakeMaexxna : BlackHole!CreatureHost
    {
        uint entry = 15_952; // Maexxna
        EntityRef[] teleported, summoned;
        Signal[] signals;
        uint[] casts;
        uint picks;
        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(entry) << 24)); }
        override EntityRef hostSelectTarget(Pick, uint, uint) { return EntityRef(7 + picks++ % 4); }
        override ActionResult hostTeleportPlayer(EntityRef who, Location) { teleported ~= who; return ActionResult.ok; }
        override ActionResult hostSignal(EntityRef to, uint id, int value) { signals ~= Signal(to, id, value); return ActionResult.ok; }
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override bool hostAlive(EntityRef) { return true; }
        override EntityRef hostSummon(uint e, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(e) << 24) | summoned.length);
            return summoned[$ - 1];
        }
        override size_t hostCreaturesNearby(uint e, float, EntityRef[] into)
        {
            if (e != npcInvisibleMan)
                return 0;
            foreach (i; 0 .. 6)
                into[i] = EntityRef(0xF130_0000_0000_0000UL | (ulong(e) << 24) | (i + 1));
            return 6;
        }
    }

    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeMaexxna;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_maexxna");
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.tick(h, me, 20_000);
    assert(host.teleported.length == 3 && host.signals.length == 3);
    foreach (i, s; host.signals)
    {
        assert(s.id == NaxxSignal.webWrapPull && s.from.entry == npcInvisibleMan); // `from`: whom it went to
        foreach (t; host.signals[0 .. i])
            assert(t.from != s.from, "a wall each");
    }

    auto man = new FakeMaexxna;
    man.entry = npcInvisibleMan;
    auto manCtx = CreatureContext(man);
    auto m = runtime.create(ScriptKind.creature, "npc_invible_man");
    runtime.raise(m, manCtx, Signal(host.hostSelf(), NaxxSignal.webWrapPull, 9));
    runtime.tick(m, manCtx, 5000);
    assert(man.casts.canFind(Maexxna.webWrapStun) && man.summoned.length == 1 && man.signals[$ - 1].value == 9);
}

/// Gothik lost to his fight (he gave it up, or his checkpoint could not bring him back): the gates open again.
unittest
{
    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeNecropolis;
    auto copy = InstanceContext(host);
    auto h = runtime.create(ScriptKind.instance, "instance_naxxramas");
    const entryGate = naxxObject(181_124);
    const gothik = EntityRef(0xF130_0000_0000_0003UL | (ulong(npcGothik) << 24));
    runtime.raise(h, copy, ObjectLoaded(entryGate));
    runtime.raise(h, copy, CreatureLoaded(gothik));
    runtime.raise(h, copy, Signal(gothik, NaxxEncounter.gothik, EncounterState.inProgress));
    assert(!host.opened[entryGate.guid], "shut while he fights");
    runtime.raise(h, copy, CreatureEvaded(gothik));
    assert(host.opened[entryGate.guid], "open once he is gone from the fight");
}

version (unittest)
{
    /// Sapphiron's lair for the copy's script: what it made, fought and let go of.
    class FakeLair : FakeNecropolis
    {
        EntityRef[] objects, despawnedObjects, zoned;
        uint[] objectSeconds;
        override EntityRef hostSummonObject(uint entry, Location, uint seconds)
        {
            objects ~= EntityRef(0xF110_0000_0000_0200UL | (ulong(entry) << 24) | objects.length);
            objectSeconds ~= seconds;
            return objects[$ - 1];
        }
        override ActionResult hostDespawnObject(EntityRef o) { despawnedObjects ~= o; return ActionResult.ok; }
        override bool hostLocationOf(EntityRef, out Location at) { at = Location(3532, -5236, 137.7f); return true; }
        override ActionResult hostZoneCombat(EntityRef c) { zoned ~= c; return ActionResult.ok; }
    }
}

/**
 * Sapphiron's fight in the copy's checkpoint: under way, he and his ice blocks are saved (the blocks stand until he
 * lands). A copy restored mid-fight waits for the raid with them, and each player back joins his fight; one saved
 * without him (an older save) fails, and he comes again as the raid returns, as he does after a wipe. Born and not
 * come yet, his timer waits for the raid; slain, he comes no more.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;

    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto lair = new FakeLair;
    auto h = runtime.create(ScriptKind.instance, "instance_naxxramas");
    int ask(FakeLair host, typeof(h) of)
    {
        auto c = InstanceContext(host);
        runtime.raise(of, c, Asked(EntityRef.init, NaxxEncounter.sapphiron));
        return c.answerGiven;
    }
    {
        auto c = InstanceContext(lair);
        runtime.raise(h, c, Signal(EntityRef.init, NaxxEncounter.sapphiron, EncounterState.special));
        assert(c.checkpointRequested, "his birth is saved at once");
    }
    ByteWriter born;
    runtime.save(h, born);
    {
        auto c = InstanceContext(lair);
        runtime.tick(h, c, 22_000);
    }
    assert(lair.summoned.length == 1 && lair.summoned[0].entry == npcSapphiron);
    const sap = lair.summoned[0];
    {
        auto c = InstanceContext(lair);
        runtime.raise(h, c, CreatureLoaded(sap, true));
        runtime.raise(h, c, Signal(sap, NaxxEncounter.sapphiron, EncounterState.inProgress));
        assert(c.checkpointSummons == [sap], "his fight under way: he is saved with the copy");
    }
    {
        auto c = InstanceContext(lair);
        runtime.raise(h, c, Signal(sap, NaxxSignal.freezePlayer, 7));
        assert(lair.objects.length == 1 && lair.objects[0].entry == goIceBlock && lair.objectSeconds == [0],
            "the block stands until he lands");
        assert(c.checkpointSummons == lair.objects, "the block is saved with him");
    }
    const block = lair.objects[0];
    ByteWriter fighting;
    runtime.save(h, fighting);

    // A worker's crash with the player frozen: he and the block come back; each player back joins his fight.
    auto lair2 = new FakeLair;
    auto h2 = runtime.create(ScriptKind.instance, "instance_naxxramas");
    auto reader = ByteReader(fighting.data);
    assert(runtime.load(h2, reader));
    {
        auto c = InstanceContext(lair2);
        c.savedSummons = [sap, block];
        runtime.raise(h2, c, Restored());
        assert(c.waitingForPlayer && !c.releasedCheckpointActors.length);
    }
    assert(ask(lair2, h2) == EncounterState.inProgress);
    {
        auto c = InstanceContext(lair2);
        runtime.raise(h2, c, CreatureLoaded(sap, true));
        runtime.raise(h2, c, ObjectLoaded(block));
        runtime.raise(h2, c, PlayerEntered(EntityRef(7)));
        runtime.raise(h2, c, PlayerEntered(EntityRef(8)));
        runtime.tick(h2, c, 1000);
    }
    assert(lair2.zoned == [sap, sap] && !lair2.summoned.length, "back in his fight, and no second Sapphiron");
    {
        auto c = InstanceContext(lair2);
        runtime.raise(h2, c, Signal(sap, NaxxSignal.clearIceBlocks));
        assert(lair2.despawnedObjects == [block] && c.releasedCheckpointActors == [block], "he landed: the block melts");
    }
    {
        auto c = InstanceContext(lair2);
        runtime.raise(h2, c, Signal(sap, NaxxSignal.freezePlayer, 8));
        runtime.raise(h2, c, Signal(sap, NaxxEncounter.sapphiron, EncounterState.failed));
        assert(lair2.despawnedObjects.length == 2 && c.releasedCheckpointActors.canFind(sap)
            && c.releasedCheckpointActors.canFind(lair2.objects[0]), "a wipe lets him and his blocks go");
    }
    assert(ask(lair2, h2) == EncounterState.failed);

    // A save of his fight without him (an older one, or he was lost): the fight failed, and he comes again.
    auto lair3 = new FakeLair;
    auto h3 = runtime.create(ScriptKind.instance, "instance_naxxramas");
    reader = ByteReader(fighting.data);
    assert(runtime.load(h3, reader));
    {
        auto c = InstanceContext(lair3);
        c.savedSummons = [block];
        runtime.raise(h3, c, Restored());
        assert(c.releasedCheckpointActors == [block], "the block of a fight not resumed is let go");
        runtime.raise(h3, c, PlayerEntered(EntityRef(7)));
        runtime.tick(h3, c, 200);
    }
    assert(ask(lair3, h3) == EncounterState.failed && lair3.summoned.length == 1
        && lair3.summoned[0].entry == npcSapphiron, "the wing is shut: no Sapphiron to fight again");
    {
        auto c = InstanceContext(lair3);
        runtime.raise(h3, c, CreatureLoaded(lair3.summoned[0], true));
        runtime.raise(h3, c, PlayerEntered(EntityRef(8)));
        runtime.tick(h3, c, 200);
    }
    assert(lair3.summoned.length == 1, "he came twice");

    // Born before the crash, not come yet: he comes on the birth's timer, once.
    auto lair4 = new FakeLair;
    auto h4 = runtime.create(ScriptKind.instance, "instance_naxxramas");
    reader = ByteReader(born.data);
    assert(runtime.load(h4, reader));
    {
        auto c = InstanceContext(lair4);
        runtime.raise(h4, c, Restored());
        assert(c.waitingForPlayer, "his timer waits for the raid");
        runtime.raise(h4, c, PlayerEntered(EntityRef(7)));
        runtime.tick(h4, c, 21_000);
    }
    assert(!lair4.summoned.length, "he came before the birth's 22 seconds");
    {
        auto c = InstanceContext(lair4);
        runtime.tick(h4, c, 1000);
    }
    assert(lair4.summoned.length == 1);

    // Slain: his death is for the lockout, and nothing comes back.
    {
        auto c = InstanceContext(lair2);
        runtime.raise(h2, c, Signal(sap, NaxxEncounter.sapphiron, EncounterState.inProgress));
        runtime.raise(h2, c, CreatureDied(sap, EntityRef(7), true));
        assert(c.releasedCheckpointActors.canFind(sap));
    }
    ByteWriter slain;
    runtime.save(h2, slain);
    auto lair5 = new FakeLair;
    auto h5 = runtime.create(ScriptKind.instance, "instance_naxxramas");
    reader = ByteReader(slain.data);
    assert(runtime.load(h5, reader));
    {
        auto c = InstanceContext(lair5);
        runtime.raise(h5, c, Restored());
        runtime.raise(h5, c, PlayerEntered(EntityRef(7)));
        runtime.tick(h5, c, 30_000);
    }
    assert(ask(lair5, h5) == EncounterState.done && !lair5.summoned.length);
}

/**
 * Sapphiron asks the copy to save him after each change his crash must not lose, never before it: as he freezes a
 * player his saved state already counts the Icebolt and has the next one pending. Born he takes the raid at once;
 * come again after a wipe and a restart, he waits to be pulled. His breath, landed, is saved.
 */
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.script.state : loadScript;

    static class FakeFrostwyrm : BlackHole!CreatureHost
    {
        int lair = EncounterState.failed;
        bool zoned;
        Signal[] dungeon;
        void delegate(uint id) onSignal;
        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0100UL | (ulong(npcSapphiron) << 24)); }
        override uint hostHealthPercent() { return 80; }
        override int hostAskDungeon(uint) { return lair; }
        override void hostZoneCombat() { zoned = true; }
        override ActionResult hostCast(uint, EntityRef, bool) { return ActionResult.ok; }
        override ActionResult hostCastAs(EntityRef, uint, EntityRef, bool) { return ActionResult.ok; }
        override bool hostHasAura(EntityRef who, uint spell) { return who.isPlayer && spell == Sapphiron.icebolt; }
        override bool hostAlive(EntityRef) { return true; }
        override bool hostLocationOf(EntityRef who, out Location at)
        {
            at = Location(3532, -5236 + cast(float)(who.guid % 100), 137.7f);
            return true;
        }
        override size_t hostThreatList(EntityRef[] into)
        {
            into[0] = EntityRef(7);
            into[1] = EntityRef(8);
            return 2;
        }
        override void hostSignalDungeon(uint id, int value)
        {
            dungeon ~= Signal(EntityRef.init, id, value);
            if (onSignal !is null)
                onSignal(id);
        }
    }

    alias self = dmangos.scripts.naxxramas;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeFrostwyrm;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_sapphiron");
    runtime.raise(h, me, Spawned());
    assert(!host.zoned, "come again after a wipe, he waits to be pulled");
    auto born = new FakeFrostwyrm;
    born.lair = EncounterState.special;
    auto bornMe = CreatureContext(born);
    auto bh = runtime.create(ScriptKind.creature, "boss_sapphiron");
    runtime.raise(bh, bornMe, Spawned());
    assert(born.zoned, "born, he takes the raid in his lair");

    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    assert(host.dungeon[$ - 1].id == NaxxSignal.saveSapphiron, "his timers saved as the fight begins");
    runtime.tick(h, me, 46_000);
    assert(host.dungeon[$ - 1].id == NaxxSignal.saveSapphiron, "his rise saved");

    // What the copy saves as it makes the block.
    Sapphiron atFreeze;
    host.onSignal = (uint id) {
        if (id != NaxxSignal.freezePlayer)
            return;
        ByteWriter w;
        runtime.save(h, w);
        auto r = ByteReader(w.data);
        assert(loadScript(atFreeze, r));
    };
    runtime.tick(h, me, 8000);
    assert(host.dungeon[$ - 1].id == NaxxSignal.freezePlayer, "nobody frozen");
    assert(atFreeze.icebolts == 1 && atFreeze.frozen.length == 1 && atFreeze.splashed.length == 2
        && atFreeze.steps.remaining(Sapphiron.Step.icebolt) == 3000,
        "saved with the block before he counted the Icebolt and timed the next: a crash leaves him in the air for good");
    host.onSignal = null;
    host.dungeon = null;
    runtime.raise(h, me, CreatureCastFinished(Sapphiron.frostBreath));
    assert(host.dungeon == [Signal(EntityRef.init, NaxxSignal.saveSapphiron, 0)], "his breath landed is not saved");
}
