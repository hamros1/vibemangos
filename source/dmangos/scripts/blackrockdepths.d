/**
 * Blackrock Depths (map 230): the Ring of Law (High Justice Grimstone sentences who walks into the
 * arena: two waves of beasts through the east gate, a champion through the north gate, and the way
 * on opens; with the Banner of Provocation planted, before the fight or during the beasts, Theldren and
 * four of his gladiators come instead of the champion, for "The Challenge"), the Tomb of the Seven (Doomrel's challenge: the seven dwarves one after another; then
 * their chest and the tomb's far door), the Lyceum's two braziers (lit, the golem rooms open), the
 * Iron Hall (Magmus's fight shuts its doors and wakes the Ironhand Guardians; his death opens the
 * throne room), the Relic Vault (the twelve coffers opened, Watcher Doomgrip and his constructs;
 * then the secret door and safe), the Grim Guzzler (Rocknot's ale, which ends in a broken keg and an
 * open bar door; Plugger Spazzring and his stolen mugs; Hurley Blackbreath, called by three broken
 * kegs; Phalanx at the door), the ambush on the Shadowforge bridge, and the bosses' abilities:
 * Emperor Dagran Thaurissan and Moira, Ambassador Flamelash and the burning spirits of the runes,
 * General Angerforge's alarm, High Interrogator Gerstahn; and "Jail Break!" (Marshal Windsor led
 * through the prison, Dughal Stormwing and Tobias Seecher freed, the cells' prisoners dealt with).
 */
module dmangos.scripts.blackrockdepths;

import dmangos.script;

/// Creatures of the depths.
enum : uint
{
    emperor = 9019,
    princess = 8929,
    haterel = 9034,
    angerrel = 9035,
    vilerel = 9036,
    gloomrel = 9037,
    seethrel = 9038,
    doomrel = 9039,
    doperel = 9040,
    magmus = 9938,
    watcherDoomgrip = 9476,
    warbringerConstruct = 8905,
    loregrain = 9024,
    fireguardDestroyer = 8911,
    shadowforgeSenator = 8904,
    anvilrageGuardman = 8891,
    anvilrageMedic = 8894,
    anvilrageReservist = 8901,
    phalanx = 9502,
    grimPatron = 9545,
    guzzlingPatron = 9547,
    hammeredPatron = 9554,
    hurleyBlackbreath = 9537,
    blackbreathCrony = 9541,
    plugger = 9499,
    rocknot = 9503,
    nagmara = 9500,
    ribbly = 9543,
    grimstone = 10096,
    burningSpirit = 9178,
    ironhandGuardian = 8982,
    marshalWindsor = 9023,
    reginaldWindsor = 9682,
    dughal = 9022,
    tobias = 9679,
    ograbisi = 9677,
    shill = 9678,
    crest = 9680,
    jaz = 9681,
    // Ring of Law: beasts (with how many come in each of the two waves) and champions.
    worm = 8925, stinger = 8926, screecher = 8927, thundersnout = 8928, creeper = 8933, beetle = 8932,
    gorosh = 9027, grizzle = 9028, eviscerator = 9029, okthor = 9030, anubshiah = 9031, hedrum = 9032,
    theldren = 16059,
    theldrenCredit = 16166, // "The Challenge"'s kill credit
}

/// Objects of the depths.
enum : uint
{
    arenaGate1 = 161525, // east (the beasts)
    arenaGate2 = 161522, // north (the champion)
    arenaGate3 = 161524, // the way on
    arenaGate4 = 161523, // the way in
    barKegShot = 170607,
    barDoor = 170571,
    tombEnter = 170576,
    tombExit = 170577,
    lyceum = 170558,
    golemRoomN = 170573,
    golemRoomS = 170574,
    throneRoom = 170575,
    chestSeven = 169243,
    arenaSpoils = 181074,
    secretDoor = 174553,
    secretSafe = 161495,
    dwarfRuneA = 170578, // the seven runes: 170578 to 170584
}

/// Which way an encounter has gone.
enum Fight : ubyte { notStarted, inProgress, done, failed }

/// What the depths remember (`instance.data`).
@instance("instance_blackrock_depths")
struct BlackrockDepths
{
    /// Signals from the depths' objects, triggers and creatures.
    enum Signals : uint
    {
        ringTrigger = 100, tombChallenge = 101, brazier = 102, cofferOpened = 103, aleGiven = 104,
        rocknotDone = 105, kegBroken = 106, mugStolen = 107, bridgeTrigger = 108, hurleyArrived = 109,
        flamelash = 110, jailPrisoner = 111, jailSupplyDoor = 112, barDoorOpened = 113,
        theldrenBanner = 114, // the Banner of Provocation planted (npc_theldren_trigger)
    }
    enum : int
    {
        sayStart1 = -1230004, sayStart2 = -1230005, sayEastGate = -1230006, sayBoss1 = -1230007,
        sayBoss2 = -1230008, sayNorthGate = -1230009, sayDoomrelStart = -1230003, sayMagmusIntro = -1230070,
        yellSenator1 = -1230060, sayGuardAggro = -1230043, sayPatronPissed1 = -1230037, sayRocknotDespawn = -1230047,
    }
    enum uint factionDwarfHostile = 754, factionDarkIron = 54;

    static immutable uint[6] beasts = [worm, stinger, screecher, thundersnout, creeper, beetle];
    static immutable ubyte[6] beastCount = [4, 2, 5, 3, 3, 7];
    static immutable uint[6] champions = [gorosh, grizzle, eviscerator, okthor, anubshiah, hedrum];
    /// Theldren's possible gladiators (four come with him): Lefty, Rotfang, Snokh, Malgen, Korv, Rezznik,
    /// Va'jashni and Volida.
    static immutable uint[8] gladiators = [16049, 16050, 16051, 16052, 16053, 16054, 16055, 16058];
    static immutable uint[7] tombDwarves = [angerrel, seethrel, doperel, gloomrel, vilerel, haterel, doomrel];
    static immutable Location eastSpawn = Location(608.960f, -235.322f, -53.907f, 1.857f);
    static immutable Location northSpawn = Location(644.300f, -175.989f, -53.739f, 3.418f);
    static immutable Location grimstonePlace = Location(625.559f, -205.618f, -52.735f, 2.609f);
    static immutable Location vaultPlace = Location(821.905f, -338.382f, -50.134f, 3.78736f);
    static immutable Location hurleyPlace = Location(856.0867f, -149.7469f, -49.6719f, 0.05949629f);
    static immutable Location[2] bridgeGuards = [
        Location(642.3660f, -274.5155f, -43.10918f, 0.4712389f), Location(740.1137f, -283.3448f, -42.75082f, 2.8623400f),
    ];
    static immutable Location[7] runes = [
        Location(1029.22f, -257.987f, -61.9462f), Location(1046.23f, -241.007f, -61.9462f),
        Location(1012.28f, -274.911f, -61.9462f), Location(1029.29f, -224.058f, -61.9462f),
        Location(995.262f, -257.966f, -61.9462f), Location(1012.31f, -207.095f, -61.9462f),
        Location(978.344f, -240.967f, -61.9462f),
    ];

    // The Ring of Law.
    Fight ring;
    ubyte ringStage;
    bool banner, theldrenFight; /// the Banner of Provocation planted; Theldren came for it
    EntityRef ringPlayer, grimstoneRef;
    Pack!24 ringMobs;              /// two waves of beetles are fourteen
    ubyte ringBeast;               /// the run's beasts (both waves the same kind)
    // The Tomb of the Seven.
    Fight tomb;
    ubyte dwarfRound;
    EntityRef tombPlayer;
    // The Lyceum and the Iron Hall.
    ubyte braziersLit;
    Fight lyceumDoors, ironHall;
    // The Relic Vault.
    ubyte coffersOpened;
    Fight vault;
    Pack!16 vaultGuards;
    // The Grim Guzzler.
    bool rocknotDone, barDoorOpen, pluggerDead, hurleyCalled, bridgeDone;
    ubyte kegsBroken, mugsStolen;
    Pack!8 cronies;
    Fight flamelashFight;

    @transient EntityRef[4] arenaGates;
    @transient EntityRef tombIn, tombOut, golemN, golemS, throne, secretDoorRef, safe, barDoorRef, kegShot;
    @transient EntityRef[7] runeObjects;
    @transient EntityRef[7] dwarves;
    @transient bool tombRecovering;
    @transient EntityRef magmusRef, emperorRef, pluggerRef, phalanxRef, rocknotRef, nagmaraRef, loregrainRef;
    @transient Pack!16 constructs;
    @transient Pack!80 patrons;
    @transient Pack!8 guardians;
    bool senatorYellCooling;
    @transient EntityRef windsorRef, supplyDoor;

    enum Step : ubyte { ring, nextDwarf, senatorYell }
    Schedule!(Step, 4) steps;

    void on(ref InstanceContext brd, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        switch (entry)
        {
        case arenaGate1, arenaGate2, arenaGate3, arenaGate4:
            arenaGates[gateIndex(entry)] = e.object;
            if (ring == Fight.done && (entry == arenaGate3 || entry == arenaGate4))
                brd.door(e.object, true);
            else if (ring == Fight.failed && entry != arenaGate3)
                brd.door(e.object, entry == arenaGate4);
            else if (ring == Fight.inProgress)
            {
                switch (entry)
                {
                case arenaGate1: brd.door(e.object, ringStage >= 3 && ringStage <= 5); break;
                case arenaGate2: brd.door(e.object, ringStage >= 6); break;
                case arenaGate3: brd.door(e.object, false); break;
                case arenaGate4: brd.door(e.object, ringStage < 2); break;
                default: break;
                }
            }
            break;
        case tombEnter:
            tombIn = e.object;
            if (tomb == Fight.inProgress || tomb == Fight.done)
                brd.door(e.object, tomb == Fight.done);
            break;
        case tombExit:
            tombOut = e.object;
            if (tomb == Fight.done)
                brd.door(e.object, true);
            break;
        case golemRoomN, golemRoomS:
            (entry == golemRoomN ? golemN : golemS) = e.object;
            if (lyceumDoors == Fight.done && ironHall != Fight.inProgress)
                brd.door(e.object, true);
            break;
        case throneRoom:
            throne = e.object;
            if (ironHall == Fight.done)
                brd.door(e.object, true);
            break;
        case secretDoor:
            secretDoorRef = e.object;
            if (vault == Fight.done)
                brd.door(e.object, true);
            break;
        case secretSafe:
            safe = e.object;
            if (vault == Fight.done)
                brd.objectFlags(e.object, 0, ObjectFlag.noInteract);
            break;
        case barDoor:
            barDoorRef = e.object;
            if (barDoorOpen)
                brd.door(e.object, true);
            break;
        case barKegShot: kegShot = e.object; break;
        case 170561: supplyDoor = e.object; break; // the prison's supply room
        default:
            if (entry >= dwarfRuneA && entry < dwarfRuneA + 7)
                runeObjects[entry - dwarfRuneA] = e.object;
            break;
        }
    }

    void on(ref InstanceContext brd, const ref Restored e)
    {
        // A boss's death reaches the database as it happens, the state it settles with the next save: a crash
        // between the two leaves him dead and his doors shut.
        if (ironHall != Fight.done && brd.entryKilled(magmus))
            ironHall = Fight.done;
        if (vault == Fight.inProgress)
        {
            EntityRef[] lost;
            foreach (guard; vaultGuards)
                if (brd.killed(guard) || (guard.entry == watcherDoomgrip && !brd.hasSavedCreature(guard)))
                    lost ~= guard; // dead, or a watcher an older save did not keep
            foreach (guard; lost)
                vaultGuards.died(guard);
            if (vaultGuards.allDead)
                vault = Fight.done;
            else if (brd.hasSavedCreature(watcherDoomgrip))
                brd.waitForPlayer();
        }
        if (hurleyCalled && (brd.hasSavedCreature(hurleyBlackbreath) || brd.hasSavedCreature(blackbreathCrony)))
            brd.waitForPlayer();
        if (tomb == Fight.inProgress)
        {
            tombRecovering = true;
            brd.waitForPlayer();
        }
        if (ring != Fight.inProgress)
            return;
        // An older or incomplete checkpoint cannot safely resume a wave with missing opponents.
        foreach (mob; ringMobs)
            if (!brd.hasSavedCreature(mob))
                return failRing(brd);
        if (!ringMobs.alive && !steps.pending(Step.ring))
        {
            failRing(brd);
            return;
        }
        grimstoneRef = EntityRef.init;
        brd.waitForPlayer();
    }

    void on(ref InstanceContext brd, const ref PlayerEntered e)
    {
        if (tombRecovering)
        {
            tombRecovering = false;
            if (brd.entryKilled(doomrel))
                finishTomb(brd);
            else
            {
                foreach (dwarf; dwarves[0 .. dwarfRound])
                {
                    const victim = brd.victimOf(dwarf);
                    awakenDwarf(brd, dwarf, !victim || !brd.alive(victim) ? e.player : EntityRef.init);
                }
                // The spawn death can reach the database just before its encounter checkpoint.
                if (dwarfRound && brd.entryKilled(tombDwarves[dwarfRound - 1]))
                    callNextDwarf(brd);
            }
        }
        if (ring == Fight.inProgress && !grimstoneRef)
        {
            grimstoneRef = brd.summon(grimstone, grimstonePlace);
            foreach (mob; ringMobs)
                if (!brd.alive(brd.victimOf(mob)))
                    brd.attack(mob, e.player);
        }
    }

    void on(ref InstanceContext brd, const ref CreatureLoaded e)
    {
        const entry = e.creature.entry;
        foreach (i, dwarf; tombDwarves)
            if (entry == dwarf)
                dwarves[i] = e.creature;
        switch (entry)
        {
        case magmus: magmusRef = e.creature; break;
        case emperor: emperorRef = e.creature; break;
        case princess:
            if (brd.entryKilled(emperor))
                brd.signal(e.creature, Moira.Signals.emperorDead);
            break;
        case plugger: pluggerRef = e.creature; break;
        case phalanx: phalanxRef = e.creature; break;
        case loregrain: loregrainRef = e.creature; break;
        case marshalWindsor: windsorRef = e.creature; break;
        case rocknot, nagmara:
            if (pluggerDead)
                brd.despawn(e.creature);
            else
                (entry == rocknot ? rocknotRef : nagmaraRef) = e.creature;
            break;
        case grimstone: grimstoneRef = e.creature; break;
        case warbringerConstruct: constructs.add(e.creature); break;
        case ironhandGuardian:
            guardians.add(e.creature);
            if (ironHall == Fight.inProgress || ironHall == Fight.done)
                brd.signal(e.creature, IronhandGuardian.Signals.wake);
            break;
        case grimPatron, guzzlingPatron, hammeredPatron:
            patrons.add(e.creature);
            if (pluggerDead)
                brd.setFaction(e.creature, factionDarkIron);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext brd, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.theldrenBanner:
            // Before the fight, or while the beasts come: Theldren will come instead of a champion.
            if (ring != Fight.done && !(ring == Fight.inProgress && ringStage > 6))
                banner = true;
            break;
        case Signals.ringTrigger:
            if (ring == Fight.notStarted || ring == Fight.failed)
            {
                ring = Fight.inProgress;
                ringStage = 0;
                ringPlayer = e.from;
                ringMobs.clear();
                grimstoneRef = brd.summon(grimstone, grimstonePlace);
                steps.after(Step.ring, 1.seconds);
            }
            break;
        case Signals.tombChallenge:
            if (tomb == Fight.notStarted || tomb == Fight.failed)
            {
                tomb = Fight.inProgress;
                dwarfRound = 0;
                if (tombIn)
                    brd.door(tombIn, false);
                callNextDwarf(brd);
            }
            break;
        case Signals.brazier:
            if (++braziersLit >= 2 && lyceumDoors != Fight.done)
            {
                lyceumDoors = Fight.done;
                openGolemRooms(brd, true);
                if (magmusRef)
                    brd.say(magmusRef, sayMagmusIntro);
            }
            break;
        case Signals.cofferOpened:
            if (vault == Fight.notStarted && ++coffersOpened >= 12)
                openVault(brd);
            break;
        case Signals.rocknotDone:
            rocknotDone = true;
            openBarDoor(brd);
            if (phalanxRef)
                brd.signal(phalanxRef, Phalanx.Signals.toTheDoor, 0);
            pissPatrons(brd);
            break;
        case Signals.kegBroken:
            if (!hurleyCalled && ++kegsBroken >= 3)
                callHurley(brd);
            break;
        case Signals.mugStolen:
            if (pluggerDead || !pluggerRef)
                break;
            ++mugsStolen;
            brd.signal(pluggerRef, Plugger.Signals.thief, mugsStolen);
            break;
        case Signals.bridgeTrigger:
            if (!bridgeDone)
            {
                bridgeDone = true;
                foreach (at; bridgeGuards)
                    if (const guard = brd.summon(anvilrageGuardman, at, 0, e.from))
                        brd.say(guard, sayGuardAggro, e.from);
            }
            break;
        case Signals.hurleyArrived:
            foreach (crony; cronies)
            {
                brd.unitFlags(crony, UnitFlag.immuneToPlayer | UnitFlag.immuneToNpc, false);
                if (const target = brd.anyPlayer())
                    brd.attack(crony, target);
            }
            break;
        case Signals.jailPrisoner:
            if (windsorRef)
                brd.signal(windsorRef, MarshalWindsor.Signals.prisonerDone);
            break;
        case Signals.barDoorOpened:
            openBarDoor(brd);
            break;
        case Signals.jailSupplyDoor:
            if (supplyDoor)
                brd.door(supplyDoor, true);
            break;
        case Signals.flamelash:
            // A rune lit for a spirit (value: the rune, 0 to 6): a burning spirit comes from it.
            if (e.value >= 0 && e.value < 7)
                if (const spirit = brd.summon(burningSpirit, runes[e.value], 60_000))
                {
                    Location at;
                    if (e.from && brd.locationOf(e.from, at))
                        brd.moveTo(spirit, at, 0, true);
                }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext brd, const ref CreatureEngaged e)
    {
        if (e.creature.entry == magmus && ironHall != Fight.done)
        {
            ironHall = Fight.inProgress;
            openGolemRooms(brd, false);
            foreach (guardian; guardians)
                brd.signal(guardian, IronhandGuardian.Signals.wake);
        }
        else if (e.creature.entry == 9156 && flamelashFight != Fight.done) // Ambassador Flamelash
        {
            flamelashFight = Fight.inProgress;
            toggleRunes(brd, true);
        }
    }

    void on(ref InstanceContext brd, const ref CreatureEvaded e)
    {
        const entry = e.creature.entry;
        if (ring == Fight.inProgress && ringMobs.has(e.creature))
            failRing(brd);
        // One of the Seven called down gave up: the challenge fails. One not called yet (pulled in by another's call
        // for help, while still friendly) does not count.
        foreach (i, dwarf; tombDwarves)
            if (entry == dwarf && tomb == Fight.inProgress && i < dwarfRound)
                failTomb(brd);
        if (entry == magmus && ironHall == Fight.inProgress)
        {
            ironHall = Fight.failed;
            openGolemRooms(brd, true);
        }
        if (entry == 9156 && flamelashFight == Fight.inProgress)
        {
            flamelashFight = Fight.failed;
            toggleRunes(brd, false);
        }
    }

    void on(ref InstanceContext brd, const ref CreatureDied e)
    {
        const entry = e.creature.entry;
        if (ring == Fight.inProgress && ringMobs.died(e.creature))
        {
            if (ringMobs.allDead)
                steps.after(Step.ring, 5.seconds);
            brd.checkpoint();
        }
        vaultGuards.died(e.creature);
        if (cronies.died(e.creature))
            brd.releaseCheckpointActor(e.creature);
        switch (entry)
        {
        case watcherDoomgrip, warbringerConstruct:
            if (entry == watcherDoomgrip)
                brd.releaseCheckpointActor(e.creature);
            if (vault == Fight.inProgress && vaultGuards.allDead)
            {
                vault = Fight.done;
                if (secretDoorRef)
                    brd.door(secretDoorRef, true);
                if (safe)
                    brd.objectFlags(safe, 0, ObjectFlag.noInteract);
            }
            break;
        case hurleyBlackbreath:
            brd.releaseCheckpointActor(e.creature);
            break;
        case haterel, angerrel, vilerel, gloomrel, seethrel, doperel:
            if (tomb == Fight.inProgress)
            {
                if (dwarfRound && entry == tombDwarves[dwarfRound - 1])
                    callNextDwarf(brd);
                brd.checkpoint();
            }
            break;
        case doomrel:
            if (tomb != Fight.done)
                finishTomb(brd);
            break;
        case magmus:
            ironHall = Fight.done;
            openGolemRooms(brd, true);
            if (throne)
                brd.door(throne, true);
            break;
        case 9156:
            flamelashFight = Fight.done;
            toggleRunes(brd, false);
            break;
        case plugger:
            pluggerDead = true;
            if (phalanxRef)
                brd.signal(phalanxRef, Phalanx.Signals.toTheDoor, 1);
            foreach (patron; patrons)
            {
                brd.setFaction(patron, factionDarkIron);
                if (const target = brd.anyPlayer())
                    brd.attack(patron, target);
            }
            if (rocknotRef)
            {
                brd.say(rocknotRef, sayRocknotDespawn);
                brd.despawn(rocknotRef);
            }
            if (nagmaraRef)
            {
                brd.castSpell(nagmaraRef, 15341); // her vanishing
                brd.despawn(nagmaraRef, 1000);
            }
            openBarDoor(brd);
            break;
        case ograbisi, shill, crest, jaz:
            if (windsorRef)
                brd.signal(windsorRef, MarshalWindsor.Signals.prisonerDone);
            break;
        case shadowforgeSenator:
            if (emperorRef && brd.alive(emperorRef) && !senatorYellCooling)
            {
                brd.say(emperorRef, yellSenator1 - cast(int) brd.random(4));
                senatorYellCooling = true;
                steps.after(Step.senatorYell, 30.seconds);
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext brd, Step step)
    {
        final switch (step)
        {
        case Step.ring:
            ringStep(brd);
            break;
        case Step.nextDwarf:
            if (tomb == Fight.inProgress && dwarfRound < tombDwarves.length)
                callNextDwarf(brd);
            break;
        case Step.senatorYell:
            senatorYellCooling = false;
            break;
        }
    }

    /// The Ring of Law, stage by stage.
    private void ringStep(ref InstanceContext brd)
    {
        if (ring != Fight.inProgress)
            return;
        const stage = ringStage++;
        switch (stage)
        {
        case 0:
            say(brd, sayStart1);
            steps.after(Step.ring, 5.seconds);
            break;
        case 1:
            say(brd, sayStart2);
            gate(brd, arenaGate4, false); // nobody leaves
            steps.after(Step.ring, 5.seconds);
            break;
        case 2:
            say(brd, sayEastGate);
            gate(brd, arenaGate1, true);
            steps.after(Step.ring, 3.seconds);
            break;
        case 3, 4:
        {
            if (stage == 3)
                ringBeast = cast(ubyte) brd.random(6);
            else if (ringMobs.allDead)
                ringMobs.clear();
            const kind = ringBeast;
            foreach (_; 0 .. beastCount[kind])
                summonRingMob(brd, beasts[kind], eastSpawn);
            if (stage == 3)
                steps.after(Step.ring, 16.seconds);
            // after the second wave: when the beasts are slain (`CreatureDied`)
            break;
        }
        case 5:
            say(brd, brd.random(2) ? sayBoss1 : sayBoss2);
            gate(brd, arenaGate1, false);
            gate(brd, arenaGate2, true);
            steps.after(Step.ring, 5.seconds);
            break;
        case 6:
            say(brd, sayNorthGate);
            ringMobs.clear();
            if (banner)
            {
                // Theldren and four of the eight gladiators, chosen at random.
                theldrenFight = true;
                summonRingMob(brd, theldren, northSpawn);
                uint chosen;
                foreach (i, g; gladiators)
                    if (chosen < 4 && (brd.random(2) || gladiators.length - i <= 4 - chosen))
                    {
                        summonRingMob(brd, g, northSpawn);
                        ++chosen;
                    }
            }
            else
                summonRingMob(brd, champions[brd.random(6)], northSpawn);
            break;
        case 7:
            if (theldrenFight)
                brd.killCreditAll(theldrenCredit);
            banner = theldrenFight = false;
            ring = Fight.done;
            gate(brd, arenaGate2, false);
            gate(brd, arenaGate3, true);
            gate(brd, arenaGate4, true);
            if (grimstoneRef)
                brd.despawn(grimstoneRef, 2000);
            brd.log("the Ring of Law is won");
            break;
        default:
            break;
        }
    }

    private void summonRingMob(ref InstanceContext brd, uint entry, Location at)
    {
        at.x += (cast(int) brd.random(9) - 4) * 0.5f;
        at.y += (cast(int) brd.random(9) - 4) * 0.5f;
        const target = ringPlayer && brd.alive(ringPlayer) ? ringPlayer : brd.anyPlayer();
        if (const made = brd.summon(entry, at, 0, target))
            if (ringMobs.add(made))
                brd.checkpointCreature(made);
    }

    private void failRing(ref InstanceContext brd)
    {
        ring = Fight.failed;
        banner = theldrenFight = false; // the banner must be planted again (ScriptDev2's FAIL overwrites it)
        steps.cancel(Step.ring);
        foreach (mob; ringMobs)
            brd.despawn(mob);
        ringMobs.clear();
        if (grimstoneRef)
            brd.despawn(grimstoneRef);
        gate(brd, arenaGate1, false);
        gate(brd, arenaGate2, false);
        gate(brd, arenaGate4, true);
        brd.checkpoint();
    }

    private void say(ref InstanceContext brd, int text)
    {
        if (grimstoneRef)
            brd.say(grimstoneRef, text);
    }

    private void gate(ref InstanceContext brd, uint entry, bool open)
    {
        const g = arenaGates[gateIndex(entry)];
        if (g)
            brd.door(g, open);
    }

    private static size_t gateIndex(uint entry)
    {
        switch (entry)
        {
        case arenaGate1: return 0;
        case arenaGate2: return 1;
        case arenaGate3: return 2;
        default: return 3;
        }
    }

    /// The next of the Seven comes down to fight; the one after him in half a minute at most.
    private void callNextDwarf(ref InstanceContext brd)
    {
        while (dwarfRound < tombDwarves.length && brd.entryKilled(tombDwarves[dwarfRound]))
            ++dwarfRound;
        if (dwarfRound >= tombDwarves.length)
            return;
        const dwarf = dwarves[dwarfRound];
        if (!dwarf || !brd.alive(dwarf))
        {
            steps.after(Step.nextDwarf, 250.msecs);
            return;
        }
        ++dwarfRound;
        awakenDwarf(brd, dwarf, brd.anyPlayer());
        brd.checkpointCreature(dwarf);
        steps.after(Step.nextDwarf, 30.seconds);
    }

    private void awakenDwarf(ref InstanceContext brd, EntityRef dwarf, EntityRef target)
    {
        if (!dwarf || !brd.alive(dwarf))
            return;
        brd.setFaction(dwarf, factionDwarfHostile);
        brd.unitFlags(dwarf, UnitFlag.immuneToPlayer, false);
        if (target)
            brd.attack(dwarf, target);
    }

    private void finishTomb(ref InstanceContext brd)
    {
        tomb = Fight.done;
        steps.cancel(Step.nextDwarf);
        if (tombIn)
            brd.door(tombIn, true);
        if (tombOut)
            brd.door(tombOut, true);
        brd.spawnObjects(chestSeven, 3600);
        brd.checkpoint();
    }

    private void failTomb(ref InstanceContext brd)
    {
        tomb = Fight.failed;
        steps.cancel(Step.nextDwarf);
        dwarfRound = 0;
        if (tombIn)
            brd.door(tombIn, true);
        brd.checkpoint();
        foreach (dwarf; dwarves)
            if (dwarf && brd.alive(dwarf))
            {
                brd.setFaction(dwarf, 0);
                brd.unitFlags(dwarf, UnitFlag.immuneToPlayer);
            }
    }

    private void openGolemRooms(ref InstanceContext brd, bool open)
    {
        foreach (door; [golemN, golemS])
            if (door)
                brd.door(door, open);
    }

    private void openVault(ref InstanceContext brd)
    {
        vault = Fight.inProgress;
        Location at;
        foreach (construct; constructs)
            if (brd.locationOf(construct, at) && (at.x - vaultPlace.x) ^^ 2 + (at.y - vaultPlace.y) ^^ 2 < 20 * 20)
            {
                vaultGuards.add(construct);
                brd.removeAura(construct, 10255);
                if (const target = brd.anyPlayer())
                    brd.attack(construct, target);
            }
        if (const watcher = brd.summon(watcherDoomgrip, vaultPlace, 0, brd.anyPlayer()))
        {
            vaultGuards.add(watcher);
            brd.checkpointCreature(watcher);
        }
        brd.checkpoint();
    }

    private void openBarDoor(ref InstanceContext brd)
    {
        if (barDoorOpen)
            return;
        barDoorOpen = true;
        if (barDoorRef)
            brd.door(barDoorRef, true);
    }

    private void pissPatrons(ref InstanceContext brd)
    {
        uint said;
        foreach (patron; patrons)
            if (brd.random(5) == 0 && said++ < 6)
                brd.say(patron, sayPatronPissed1 - cast(int) brd.random(3));
    }

    private void callHurley(ref InstanceContext brd)
    {
        hurleyCalled = true;
        if (const hurley = brd.summon(hurleyBlackbreath, hurleyPlace))
            brd.checkpointCreature(hurley);
        foreach (i; 0 .. 3)
        {
            Location at = hurleyPlace;
            at.x += i - 1.0f;
            at.y -= 1.5f;
            if (const crony = brd.summon(blackbreathCrony, at))
            {
                cronies.add(crony);
                brd.unitFlags(crony, UnitFlag.immuneToPlayer | UnitFlag.immuneToNpc);
                brd.checkpointCreature(crony);
            }
        }
        brd.checkpoint();
    }

    private void toggleRunes(ref InstanceContext brd, bool lit)
    {
        foreach (rune; runeObjects)
            if (rune)
                brd.door(rune, lit);
    }
}

// ---------------------------------------------------------------------------
// Objects and triggers
// ---------------------------------------------------------------------------

/// The Theldren Trigger in the Ring of Law (`npc_theldren_trigger`): the Banner of Provocation (Summon Thelrin DND)
/// planted at it tells the depths' script that Theldren is challenged.
@creature("npc_theldren_trigger")
struct TheldrenTrigger
{
    enum uint summonThelrin = 27_517;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.combatMovement(false);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == summonThelrin)
            me.signalDungeon(BlackrockDepths.Signals.theldrenBanner);
    }
}

/// The Ring of Law: who walks in is sentenced.
@areaTrigger("at_ring_of_law")
struct AtRingOfLaw
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        at.signalDungeon(BlackrockDepths.Signals.ringTrigger);
    }
}

/// The Shadowforge bridge: two guards come for who crosses it (once).
@areaTrigger("at_shadowforge_bridge")
struct AtShadowforgeBridge
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        at.signalDungeon(BlackrockDepths.Signals.bridgeTrigger);
    }
}

/// A Shadowforge Brazier of the Lyceum: both lit, the golem rooms open.
@gameObject("go_shadowforge_brazier")
struct ShadowforgeBrazier
{
    bool lit;

    void on(ref GameObjectContext brazier, const ref ObjectUsed e)
    {
        if (lit)
            return;
        lit = true;
        brazier.signalDungeon(BlackrockDepths.Signals.brazier);
    }
}

/// A relic coffer's door: the twelfth opened brings Watcher Doomgrip.
@gameObject("go_relic_coffer_door")
struct RelicCofferDoor
{
    bool opened;

    void on(ref GameObjectContext door, const ref ObjectUsed e)
    {
        if (opened)
            return;
        opened = true;
        door.signalDungeon(BlackrockDepths.Signals.cofferOpened);
    }
}

/// A keg of the Grim Guzzler: the third broken brings Hurley Blackbreath.
@gameObject("go_bar_beer_keg")
struct BarBeerKeg
{
    bool broken;

    void on(ref GameObjectContext keg, const ref ObjectUsed e)
    {
        if (broken)
            return;
        broken = true;
        keg.signalDungeon(BlackrockDepths.Signals.kegBroken);
    }
}

/// A mug of Plugger's ale: taking one is noticed.
@gameObject("go_bar_ale_mug")
struct BarAleMug
{
    void on(ref GameObjectContext mug, const ref ObjectUsed e)
    {
        mug.signalDungeon(BlackrockDepths.Signals.mugStolen);
    }
}

// ---------------------------------------------------------------------------
// Creatures
// ---------------------------------------------------------------------------

/// High Justice Grimstone: he speaks for the Ring of Law (the depths' script); he cannot be attacked.
@creature("npc_grimstone")
struct Grimstone
{
    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.unitFlags(UnitFlag.notAttackable);
    }
}

/// Doomrel: his challenge, offered while the Seven have not fought, begins their fight.
@creature("boss_doomrel")
struct Doomrel
{
    enum uint challenge = 1;
    enum uint textChallenge = 2601;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Your bondage is at an end, Doom'rel. I challenge you!", challenge);
        me.sendGossip(e.player, textChallenge, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != challenge)
            return;
        me.closeGossip(e.player);
        me.say(BlackrockDepths.sayDoomrelStart);
        me.signalDungeon(BlackrockDepths.Signals.tombChallenge);
        me.consume();
    }
}

/**
 * Private Rocknot: given his ale three times he wants more, walks to the keg, smashes it in a
 * drunken rage (the bar's door with it), and goes home.
 */
@creature("npc_rocknot")
struct Rocknot
{
    enum uint questAle = 4295;
    enum : int { sayGotBeer = -1230000, sayMoreBeer = -1230036, sayBarrel1 = -1230044, sayBarrel2 = -1230045, sayBarrel3 = -1230046 }
    enum uint drunkenRage = 14872;

    enum Step : ubyte { cheer, breakKeg, breakDoor, done }
    Schedule!Step steps;
    Walk walk;
    ubyte ales;
    bool walked, inLove;

    /// From Mistress Nagmara: her potion of love, given; he goes with her (his path's second walk).
    enum Signals : uint { love = 1 }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Signals.love || inLove)
            return;
        inLove = true;
        me.npcFlags(0);
        walk.start(me, false, 9);
        walk.stopAt = 33;
    }

    void on(ref CreatureContext me, const ref QuestRewarded e)
    {
        if (e.quest != questAle || walked)
            return;
        me.say(sayGotBeer);
        ++ales;
        steps.after(Step.cheer, 1500.msecs);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        // The database's points count from 1; his ale walk is points 1 to 9, the walk with
        // Nagmara points 10 to 34.
        const point = walk.reached(me, e) + 1;
        if (inLove)
        {
            if (point == 17)
                me.signalDungeon(BlackrockDepths.Signals.barDoorOpened);
            else if (point == 34)
                if (const her = me.creatureNearby(nagmara, 40))
                    me.signal(her, MistressNagmara.Signals.underTheStairs);
            return;
        }
        switch (point)
        {
        case 3, 6: me.say(sayBarrel1); break;
        case 4, 5: me.say(sayBarrel2); break;
        case 7:
            me.castSelf(drunkenRage);
            steps.after(Step.breakKeg, 2.seconds);
            break;
        default: break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.cheer:
            if (ales >= 3 && !walked)
            {
                walked = true;
                me.say(sayMoreBeer);
                walk.start(me);
                walk.stopAt = 8; // home again: his path goes on for another walk (with Nagmara)
            }
            else
                me.emote(4); // cheer
            break;
        case Step.breakKeg:
            steps.after(Step.breakDoor, 1.seconds);
            break;
        case Step.breakDoor:
            me.say(sayBarrel3);
            steps.after(Step.done, 4.seconds);
            break;
        case Step.done:
            me.signalDungeon(BlackrockDepths.Signals.rocknotDone);
            break;
        }
    }
}

/**
 * Mistress Nagmara: after "The Love Potion" (quest 4201), her gossip starts the scene with Rocknot.
 * She sweet-talks him,
 * gives him the potion and leads him away under the stairs (opening the bar's door on the way),
 * where the two stay, kissing.
 */
@creature("npc_mistress_nagmara")
struct MistressNagmara
{
    enum Signals : uint { underTheStairs = 1 }
    enum uint quest = 4201;
    enum uint begin = 1;
    enum : uint { potionOfLove = 14928, nagmaraRocknot = 15064 }
    enum : int { say1 = -1230066, say2 = -1230067, emoteKiss = -1230068 }
    enum Location underTheStairs = Location(878.1779f, -222.0662f, -49.96714f);

    enum Step : ubyte { sweetTalk, potion, kiss }
    Schedule!Step steps;
    EntityRef lover;
    bool begun;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (begun || me.questStatus(e.player, quest) != QuestProgress.rewarded)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Why don't you and Rocknot go find somewhere private...", begin);
        me.sendGossip(e.player, 2729, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != begin || me.questStatus(e.player, quest) != QuestProgress.rewarded)
            return;
        me.closeGossip(e.player);
        start(me);
        me.consume();
    }

    private void start(ref CreatureContext me)
    {
        if (begun)
            return;
        lover = me.creatureNearby(rocknot, 80);
        Location at;
        if (!lover || !me.locationOf(lover, at))
            return;
        begun = true;
        me.npcFlags(0);
        at.x += 2;
        me.moveTo(at, 1);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == 1)
        {
            me.say(say1);
            steps.after(Step.sweetTalk, 5.seconds);
        }
        else if (e.point == 2)
            steps.every(Step.kiss, 1.seconds, 12.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.underTheStairs)
            me.moveTo(underTheStairs, 2);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.sweetTalk:
            me.say(say2);
            steps.after(Step.potion, 4.seconds);
            break;
        case Step.potion:
            me.castSpell(potionOfLove, lover);
            me.signal(lover, Rocknot.Signals.love);
            me.follow(lover, 2, 0);
            break;
        case Step.kiss:
            me.say(emoteKiss);
            me.castSelf(nagmaraRocknot);
            break;
        }
    }
}

/**
 * Phalanx: woken by the bar's trouble, he walks to the door and keeps it; he fights with thunder
 * claps, mighty blows and (below half health) fireball volleys.
 */
@creature("npc_phalanx")
struct Phalanx
{
    enum Signals : uint { toTheDoor = 1 }
    enum int yellAggro = -1230040;
    enum : uint { thunderclap = 15588, mightyBlow = 14099, fireballVolley = 15285 }
    enum uint factionIronforge = 122, factionDarkIron = 54;

    enum Step : ubyte { thunderclap, mightyBlow, volley }
    Schedule!Step steps;
    Walk walk;
    bool forPlugger, woken;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Signals.toTheDoor || woken)
            return;
        woken = true;
        forPlugger = e.value != 0;
        walk.start(me);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (walk.reached(me, e) + 1)
        {
        case 1:
            me.say(yellAggro);
            break;
        case 2:
            walk.stop();
            me.setFaction(forPlugger ? factionIronforge : factionDarkIron);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.thunderclap, 12.seconds);
        steps.after(Step.mightyBlow, 15.seconds);
        steps.every(Step.volley, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.thunderclap:
            me.castSpell(thunderclap);
            steps.after(Step.thunderclap, 10.seconds);
            break;
        case Step.mightyBlow:
            me.castSpell(mightyBlow);
            steps.after(Step.mightyBlow, 10.seconds);
            break;
        case Step.volley:
            if (me.healthPercent < 51 && me.castSelf(fireballVolley) == ActionResult.ok)
                steps.every(Step.volley, 15.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/**
 * Plugger Spazzring: talks up his ale and food, warns those who steal his mugs, and attacks the
 * third thief; banishes, curses, immolates and casts shadow bolts. His death sets the bar on the
 * players and wakes Phalanx.
 */
@creature("boss_plugger_spazzring")
struct Plugger
{
    enum Signals : uint { thief = 1 }
    enum : int { sayOoc1 = -1230050, yellStolen1 = -1230054, yellAggro1 = -1230057, yellAggro2 = -1230058 }
    enum : uint { banish = 8994, curseOfTongues = 13338, demonArmor = 13787, immolate = 12742, shadowBolt = 12739 }
    enum uint factionDarkIron = 54;

    enum Step : ubyte { ooc, banish, immolate, bolt, curse }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(demonArmor);
        steps.after(Step.ooc, 10.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Signals.thief)
            return;
        if (e.value >= 3)
        {
            me.say(me.random(2) ? yellAggro1 : yellAggro2);
            me.setFaction(factionDarkIron);
            if (const thief = me.playerNearby(40))
                me.attack(thief);
        }
        else
            me.say(yellStolen1 - cast(int) me.random(3));
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.cancel(Step.ooc);
        steps.after(Step.banish, ((8 + me.random(5)) * 1000).msecs);
        steps.after(Step.immolate, ((18 + me.random(3)) * 1000).msecs);
        steps.after(Step.bolt, 1.seconds);
        steps.after(Step.curse, 17.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.ooc:
            if (!me.inCombat)
                me.say(sayOoc1 - cast(int) me.random(4));
            steps.after(Step.ooc, ((10 + me.random(11)) * 1000).msecs);
            break;
        case Step.banish:
            if (const target = me.randomTarget())
                me.castSpell(banish, target);
            steps.after(Step.banish, ((26 + me.random(3)) * 1000).msecs);
            break;
        case Step.immolate:
            me.castSpell(immolate);
            steps.after(Step.immolate, 25.seconds);
            break;
        case Step.bolt:
            me.castSpell(shadowBolt);
            steps.after(Step.bolt, ((36 + me.random(28)) * 100).msecs);
            break;
        case Step.curse:
            if (const target = me.randomTarget())
                me.castSpell(curseOfTongues, target);
            steps.after(Step.curse, ((19 + me.random(13)) * 1000).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        steps.after(Step.ooc, 10.seconds);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/**
 * Hurley Blackbreath: called by the broken kegs, he comes running with his cronies; flame breath,
 * and a drunken rage near death.
 */
@creature("npc_hurley_blackbreath")
struct Hurley
{
    enum : int { yellSpawn = -1230041, sayAggro = -1230042 }
    enum : uint { flameBreath = 9573, drunkenRage = 14872 }

    enum Step : ubyte { breath, rage }
    Schedule!Step steps;
    Walk walk;
    bool enraged;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.unitFlags(UnitFlag.immuneToPlayer);
        walk.start(me);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (walk.reached(me, e) + 1)
        {
        case 2:
            me.say(yellSpawn);
            walk.run = true;
            break;
        case 6:
            walk.stop();
            me.unitFlags(UnitFlag.immuneToPlayer, false);
            me.signalDungeon(BlackrockDepths.Signals.hurleyArrived);
            if (const enemy = me.playerNearby(40))
                me.attack(enemy);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        steps.after(Step.breath, 7.seconds);
        steps.every(Step.rage, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.breath:
            me.castSpell(flameBreath);
            steps.after(Step.breath, 10.seconds);
            break;
        case Step.rage:
            if (!enraged && me.healthPercent < 31 && me.castSelf(drunkenRage) == ActionResult.ok)
            {
                enraged = true;
                steps.cancel(Step.rage);
            }
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// An Ironhand Guardian of the Iron Hall: stone until Magmus's fight; then it spouts flame now and then.
@creature("npc_ironhand_guardian")
struct IronhandGuardian
{
    enum Signals : uint { wake = 1 }
    enum : uint { stoned = 10255, stonedVisual = 15533, goutOfFlame = 15529 }

    enum Step : ubyte { gout }
    Schedule!Step steps;
    bool awake;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.combatMovement(false);
        me.melee(false);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Signals.wake || awake)
            return;
        awake = true;
        me.removeAura(me.self, stoned);
        me.castSelf(stonedVisual, true);
        steps.after(Step.gout, ((4 + me.random(27)) * 1000).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.castSelf(goutOfFlame);
        steps.after(Step.gout, ((20 + me.random(21)) * 1000).msecs);
    }
}

/// Emperor Dagran Thaurissan: Hand of Thaurissan on someone he fights, Avatar of Flame; he calls for help.
@creature("boss_emperor_dagran_thaurissan")
struct EmperorThaurissan
{
    enum : int { yellAggro1 = -1230001, yellAggro2 = -1230064, yellAggro3 = -1230065, yellSlay = -1230002 }
    enum : uint { handOfThaurissan = 17492, avatarOfFlame = 15636 }
    enum uint factionNeutral = 734;

    enum Step : ubyte { hand, avatar }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        static immutable int[3] yells = [yellAggro1, yellAggro2, yellAggro3];
        me.say(yells[me.random(3)]);
        steps.after(Step.hand, 4.seconds);
        steps.after(Step.avatar, 25.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.hand:
            if (const target = me.randomTarget())
                me.castSpell(handOfThaurissan, target);
            steps.after(Step.hand, ((5 + me.random(6)) * 1000).msecs);
            break;
        case Step.avatar:
            me.castSpell(avatarOfFlame);
            steps.after(Step.avatar, 18.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.say(yellSlay);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        // Moira, freed of him, fights no more.
        if (const moira = me.creatureNearby(princess, 100))
            me.signal(moira, Moira.Signals.emperorDead);
    }
}

/// Princess Moira Bronzebeard: heals her husband, mind blasts, shadow word: pain and smites.
@creature("boss_moira_bronzebeard")
struct Moira
{
    enum Signals : uint { emperorDead = 1 }
    enum : uint { heal = 15586, mindBlast = 15587, shadowWordPain = 15654, smite = 10934, openPortal = 13912 }

    enum Step : ubyte { heal, mindBlast, pain, smite }
    Schedule!Step steps;
    bool widowed;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.melee(false);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.heal, 12.seconds);
        steps.after(Step.mindBlast, 16.seconds);
        steps.after(Step.pain, 2.seconds);
        steps.after(Step.smite, 8.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.emperorDead)
        {
            widowed = true;
            me.setFaction(EmperorThaurissan.factionNeutral);
            steps.clear();
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.heal:
            if (const husband = me.creatureNearby(emperor, 50))
                if (me.healthPercentOf(husband) < 100)
                    me.castSpell(heal, husband);
            steps.after(Step.heal, 10.seconds);
            break;
        case Step.mindBlast:
            me.castSpell(mindBlast);
            steps.after(Step.mindBlast, 14.seconds);
            break;
        case Step.pain:
            me.castSpell(shadowWordPain);
            steps.after(Step.pain, 18.seconds);
            break;
        case Step.smite:
            me.castSpell(smite);
            steps.after(Step.smite, 10.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (widowed)
            me.castSelf(openPortal);
    }
}

/**
 * Ambassador Flamelash: fire blast as he starts, four Fireguard Destroyers at his side, and burning
 * spirits from the seven runes of his hall, which come to him.
 */
@creature("boss_ambassador_flamelash")
struct Flamelash
{
    enum uint fireblast = 15573;
    static immutable Location[4] destroyers = [
        Location(919.21f, -231.029f, -50.1755f, 5.65487f), Location(913.883f, -236.914f, -49.8527f, 6.03884f),
        Location(924.225f, -256.302f, -49.8526f, 1.16937f), Location(932.524f, -252.475f, -49.8526f, 1.71042f),
    ];

    enum Step : ubyte { rune0, rune1, rune2, rune3, rune4, rune5, rune6 }
    Schedule!(Step, 7) steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(fireblast);
        foreach (at; destroyers)
            me.summon(fireguardDestroyer, at, 300_000, e.enemy);
        foreach (i; 0 .. 7)
            steps.after(cast(Step) i, me.random(1000).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.signalDungeon(BlackrockDepths.Signals.flamelash, cast(int) step);
        steps.after(step, (15_000 + me.random(15_000)).msecs);
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

/// General Angerforge: flurry and enrage, sunder armor; below a third of his health he sounds the alarm.
@creature("boss_general_angerforge")
struct Angerforge
{
    enum int emoteAlarm = -1230035;
    enum : uint { flurry = 15088, enrage = 15097, sunderArmor = 15572 }
    enum Location alarmPoint = Location(717.343f, 22.116f, -45.4321f, 3.1415f);

    enum Step : ubyte { sunder, alarm }
    Schedule!Step steps;
    bool alarmed;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(flurry, true);
        me.castSelf(enrage, true);
        steps.after(Step.sunder, (5000 + me.random(5000)).msecs);
        steps.every(Step.alarm, 1.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.sunder:
            me.castSpell(sunderArmor);
            steps.after(Step.sunder, (5000 + me.random(10_000)).msecs);
            break;
        case Step.alarm:
            if (me.healthPercent >= 30)
                break;
            me.say(emoteAlarm);
            foreach (i; 0 .. 10)
            {
                Location at = alarmPoint;
                at.x += (cast(int) me.random(5) - 2) * 0.5f;
                at.y += (cast(int) me.random(5) - 2) * 0.5f;
                me.summon(i < 8 ? anvilrageReservist : anvilrageMedic, at, 30_000, me.victim);
            }
            steps.every(Step.alarm, 3 * 60.seconds);
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

/// High Interrogator Gerstahn: shadow word: pain, mana burn, psychic scream, shadow shield.
@creature("boss_high_interrogator_gerstahn")
struct Gerstahn
{
    enum : uint { shadowWordPain = 14032, manaBurn = 14033, psychicScream = 13704, shadowShield = 12040 }

    enum Step : ubyte { pain, manaBurn, scream, shield }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.pain, 4.seconds);
        steps.after(Step.manaBurn, 14.seconds);
        steps.after(Step.scream, 32.seconds);
        steps.after(Step.shield, 8.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.pain:
            if (const target = me.randomTarget())
                me.castSpell(shadowWordPain, target);
            steps.after(Step.pain, 7.seconds);
            break;
        case Step.manaBurn:
            if (const target = me.randomTarget())
                me.castSpell(manaBurn, target);
            steps.after(Step.manaBurn, 10.seconds);
            break;
        case Step.scream:
            me.castSelf(psychicScream);
            steps.after(Step.scream, 30.seconds);
            break;
        case Step.shield:
            me.castSelf(shadowShield);
            steps.after(Step.shield, 25.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

// ---------------------------------------------------------------------------
// "Jail Break!" (quest 4322)
// ---------------------------------------------------------------------------

/**
 * Marshal Windsor: escorted through the prison; he stops at each cell until its prisoner is freed
 * (Dughal and Tobias, by talking to them) or dealt with (Jaz and Ograbisi, Shill Dinger, Crest
 * Killer), takes back his gear in the supply room (as Reginald Windsor from then on), and at the
 * prison's gate the quest's event happens.
 */
@creature("npc_marshal_windsor")
struct MarshalWindsor
{
    enum Signals : uint { prisonerDone = 1 }
    enum uint quest = 4322;
    enum uint factionEscort = 231; // FACTION_ESCORT_A_NEUTRAL_ACTIVE
    enum uint windsorsFrenzy = 15167;
    enum : int
    {
        sayAggro1 = -1230011, sayAggro2 = -1230012, sayAggro3 = -1230013, sayStart = -1230014, sayDughal1 = -1230015,
        sayDughal3 = -1230016, sayEquipment1 = -1230017, sayEquipment2 = -1230018, sayEquipment3 = -1230019,
        sayEquipment4 = -1230020, sayJaz1 = -1230021, sayJaz2 = -1230022, sayShill1 = -1230023, sayShill2 = -1230024,
        sayShill3 = -1230025, sayCrest1 = -1230026, sayCrest2 = -1230027, sayTobias1 = -1230028, sayTobias2 = -1230029,
        sayFree1 = -1230030, sayFree2 = -1230031,
    }

    Escort escort;
    ubyte awaited; /// prisoners still to be dealt with at the cell he waits at

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != quest || escort.active)
            return;
        me.setFaction(factionEscort);
        escort.start(me, e.player, quest);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        static immutable int[3] lines = [sayAggro1, sayAggro2, sayAggro3];
        me.say(lines[me.random(3)], e.enemy);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != Signals.prisonerDone || !escort.paused || awaited == 0)
            return;
        if (--awaited == 0)
            escort.paused = false;
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const player = escort.player;
        // The database's points count from 1.
        switch (escort.reached(me, e) + 1)
        {
        case 1: me.say(sayStart); break;
        case 7: wait(me, sayDughal1, 1, player); break;
        case 9: me.say(sayDughal3, player); break;
        case 14: me.say(sayEquipment1, player); break;
        case 16: me.signalDungeon(BlackrockDepths.Signals.jailSupplyDoor); break;
        case 18: me.say(sayEquipment2); break;
        case 21: me.changeEntry(reginaldWindsor); break;
        case 22:
            me.castSelf(windsorsFrenzy, true);
            me.say(sayEquipment3, player);
            break;
        case 23: me.say(sayEquipment4); break;
        case 30: wait(me, sayJaz1, 2); break; // Jaz and Ograbisi
        case 32: me.say(sayJaz2); break;
        case 35: wait(me, sayShill1, 1); break;
        case 37: me.say(sayShill2); break;
        case 38: me.say(sayShill3); break;
        case 45: wait(me, sayCrest1, 1); break;
        case 47: me.say(sayCrest2); break;
        case 49: wait(me, sayTobias1, 1); break;
        case 51: me.say(sayTobias2, player); break;
        case 57: me.say(sayFree1); break;
        case 58:
            me.say(sayFree2);
            me.questEvent(player, quest);
            break;
        default: break;
        }
    }

    private void wait(ref CreatureContext me, int line, ubyte prisoners, EntityRef player = EntityRef.init)
    {
        me.say(line, player);
        escort.paused = true;
        awaited = prisoners;
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

/// A prisoner of the cells (Dughal Stormwing, Tobias Seecher): freed by one on "Jail Break!", he runs.
@creature("npc_dughal_stormwing", "npc_tobias_seecher")
struct JailPrisoner
{
    enum uint free = 1;
    enum : int { sayDughalFree = -1230010, sayTobiasFree1 = -1230032, sayTobiasFree2 = -1230033 }
    bool freed;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (freed || me.questStatus(e.player, MarshalWindsor.quest) != QuestProgress.incomplete)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Your bonds are broken. Go!", free);
        me.sendGossip(e.player, me.self.entry == dughal ? 2846 : 2847, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != free || freed)
            return;
        freed = true;
        me.closeGossip(e.player);
        if (me.self.entry == dughal)
            me.say(sayDughalFree, e.player);
        else
            me.say(me.random(2) ? sayTobiasFree1 : sayTobiasFree2);
        me.npcFlags(0);
        me.signalDungeon(BlackrockDepths.Signals.jailPrisoner);
        me.despawn(5000); // gone to safety
        me.consume();
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackrockdepths;
    auto brd = runInstance!self("instance_blackrock_depths");
    foreach (gate; [arenaGate1, arenaGate2, arenaGate3, arenaGate4])
        brd.raise(ObjectLoaded(objectRef(gate)));

    // The Ring of Law.
    brd.raise(Signal(playerRef, BlackrockDepths.Signals.ringTrigger));
    assert(brd.host.done("summon 10096"));
    brd.run(12_000);
    assert(brd.host.done("door 161523 closed") && brd.host.done("door 161525 open"));
    brd.run(20_000);
    assert(brd.host.times("summon 8925") == 8, "two waves of four worms");
    foreach (spawn; 2 .. 10)
        brd.raise(CreatureDied(creatureRef(worm, 1000 + spawn)));
    brd.run(11_000);
    assert(brd.host.done("door 161522 open") && brd.host.done("summon 9027"));
    brd.raise(CreatureDied(creatureRef(gorosh, 1010)));
    brd.run(6000);
    assert(brd.host.done("door 161524 open") && brd.host.done("door 161523 open"));
    assert(brd.state!BlackrockDepths.ring == Fight.done);

    // The Tomb of the Seven: one dwarf after another; Doomrel's death opens the way.
    foreach (dwarf; BlackrockDepths.tombDwarves)
        brd.raise(CreatureLoaded(creatureRef(dwarf)));
    brd.raise(ObjectLoaded(objectRef(tombExit)));
    brd.raise(Signal(creatureRef(doomrel), BlackrockDepths.Signals.tombChallenge));
    assert(brd.host.done("faction 9035 754") && brd.host.done("attack 9035"));
    brd.raise(CreatureDied(creatureRef(angerrel)));
    assert(brd.host.done("faction 9038 754"));
    brd.run(30_000);
    assert(brd.host.done("faction 9040 754"), "the next comes in half a minute anyway");
    brd.raise(CreatureDied(creatureRef(doomrel)));
    assert(brd.host.done("door 170577 open") && brd.host.done("spawn objects 169243"));

    // The Lyceum's braziers, and Magmus.
    brd.raise(ObjectLoaded(objectRef(golemRoomN)));
    brd.raise(ObjectLoaded(objectRef(throneRoom)));
    brd.raise(Signal(objectRef(1), BlackrockDepths.Signals.brazier));
    assert(!brd.host.done("door 170573 open"));
    brd.raise(Signal(objectRef(2), BlackrockDepths.Signals.brazier));
    assert(brd.host.done("door 170573 open"));
    brd.raise(CreatureEngaged(creatureRef(magmus), playerRef));
    assert(brd.host.done("door 170573 closed"));
    brd.raise(CreatureDied(creatureRef(magmus)));
    assert(brd.host.done("door 170575 open"));

    // Three broken kegs: Hurley.
    foreach (_; 0 .. 3)
        brd.raise(Signal(objectRef(3), BlackrockDepths.Signals.kegBroken));
    assert(brd.host.times("summon 9537") == 1 && brd.host.times("summon 9541") == 3);

    // Rocknot's ale.
    auto rock = runCreature!self("npc_rocknot", rocknot);
    foreach (i; 0 .. 34)
        rock.host.path ~= Waypoint(Location(i, 0, 0));
    foreach (_; 0 .. 3)
    {
        rock.raise(QuestRewarded(playerRef, Rocknot.questAle));
        rock.run(1500);
    }
    assert(rock.host.done("say -1230036") && rock.host.done("move 0"));
    foreach (point; 0 .. 9)
    {
        rock.host.walking = false;
        rock.raise(MovementDone(point));
        rock.run(250);
    }
    rock.run(8000);
    assert(rock.host.done("cast 14872") && rock.host.done("say -1230046") && rock.host.done("dungeon 105 0"));
    assert(!rock.host.done("move 9"), "home again, he stays");
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackrockdepths;
    auto windsor = runCreature!self("npc_marshal_windsor", marshalWindsor);
    foreach (i; 0 .. 58)
        windsor.host.path ~= Waypoint(Location(i, 0, 0));
    windsor.raise(QuestAccepted(playerRef, MarshalWindsor.quest));
    assert(windsor.host.done("faction 231"));
    void walk(uint to)
    {
        foreach (point; windsor.state!MarshalWindsor.escort.point .. to)
        {
            windsor.host.walking = false;
            windsor.raise(MovementDone(point));
            windsor.run(250);
        }
    }
    walk(7);
    assert(windsor.host.done("say -1230015") && !windsor.host.done("move 7"), "he waits at Dughal's cell");
    windsor.raise(Signal(EntityRef.init, MarshalWindsor.Signals.prisonerDone));
    windsor.run(250);
    assert(windsor.host.done("move 7"));
    walk(30);
    assert(windsor.host.done("become 9682") && windsor.host.done("dungeon 112 0"));
    windsor.raise(Signal(EntityRef.init, MarshalWindsor.Signals.prisonerDone));
    windsor.run(250);
    assert(!windsor.host.done("move 30"), "Jaz and Ograbisi both");
    windsor.raise(Signal(EntityRef.init, MarshalWindsor.Signals.prisonerDone));
    windsor.run(250);
    assert(windsor.host.done("move 30"));
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackrockdepths;
    auto her = runCreature!self("npc_mistress_nagmara", nagmara);
    her.host.nearby = creatureRef(rocknot);
    her.host.progress = QuestProgress.complete;
    her.raise(GossipHello(playerRef));
    assert(!her.host.done("gossip 1") && !her.host.done("move 1"));
    her.host.progress = QuestProgress.rewarded;
    her.raise(QuestRewarded(playerRef, MistressNagmara.quest));
    assert(!her.host.done("move 1"), "the turn-in only unlocks the gossip option");
    her.raise(GossipHello(playerRef));
    assert(her.host.done("gossip 1"));
    her.raise(GossipSelect(playerRef, 0, 0, MistressNagmara.begin));
    her.raise(GossipSelect(playerRef, 0, 0, MistressNagmara.begin));
    assert(her.host.times("move 1") == 1, "the gossip starts the scene once");
    her.raise(MovementDone(1));
    her.run(10_000);
    assert(her.host.done("cast 14928") && her.host.done("signal 1 0") && her.host.done("follow"));

    auto him = runCreature!self("npc_rocknot", rocknot);
    foreach (i; 0 .. 34)
        him.host.path ~= Waypoint(Location(i, 0, 0));
    him.raise(Signal(creatureRef(nagmara), Rocknot.Signals.love));
    assert(him.host.done("move 9"), "off on his second walk");
}

/// The Banner of Provocation planted at the Theldren Trigger: Theldren and four gladiators come instead of the
/// champion, and their deaths credit "The Challenge".
unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackrockdepths;
    auto trigger = runCreature!self("npc_theldren_trigger", 16_079);
    trigger.raise(SpellHit(playerRef, TheldrenTrigger.summonThelrin));
    assert(trigger.host.done("dungeon 114 0"));

    auto brd = runInstance!self("instance_blackrock_depths");
    brd.raise(Signal(creatureRef(16_079), BlackrockDepths.Signals.theldrenBanner));
    brd.raise(Signal(playerRef, BlackrockDepths.Signals.ringTrigger));
    brd.run(32_000);
    foreach (spawn; 2 .. 10)
        brd.raise(CreatureDied(creatureRef(worm, 1000 + spawn)));
    brd.run(11_000);
    assert(brd.host.done("summon 16059") && !brd.host.done("summon 9027"));
    size_t gladiatorsCame;
    foreach (g; BlackrockDepths.gladiators)
        gladiatorsCame += brd.host.times(imported!"std.format".format("summon %s", g));
    assert(gladiatorsCame == 4);
    brd.raise(CreatureDied(creatureRef(theldren, 1010)));
    foreach (i, g; BlackrockDepths.gladiators[4 .. 8]) // the fake's dice: always the last four
        brd.raise(CreatureDied(creatureRef(g, cast(uint)(1011 + i))));
    brd.run(6000);
    assert(brd.host.done("credit 16166") && brd.state!BlackrockDepths.ring == Fight.done);
}
