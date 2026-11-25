/**
 * Blackrock Spire (map 229, Lower and Upper): the Dragonspine door (whoever carries the Seal of
 * Ascension lights its braziers and opens it), the seven rune rooms (each rune goes out when the
 * Blackhand around it fall; with all seven out the way to Emberseer opens), Pyroguard Emberseer
 * (woken at his altar, freed by the incarcerators' fall, he grows to full strength; his death opens
 * the way on), the Father Flame and Solakar Flamewreath's rookery waves, Warchief Rend Blackhand's
 * stadium (Lord Victor Nefarius looks on: seven waves of dragonkin and handlers, then Gyth with Rend
 * on his back), The Beast's lair, General Drakkisath's gates, and Overlord Wyrmthalak's guards.
 */
module dmangos.scripts.blackrockspire;

import dmangos.script;

/// Creatures of the spire.
enum : uint
{
    blackhandSummoner = 9818,
    blackhandVeteran = 9819,
    emberseer = 9816,
    solakar = 10264,
    incarcerator = 10316,
    blackhandElite = 10317,
    nefarius = 10162,
    rend = 10429,
    gyth = 10339,
    theBeast = 10430,
    drakkisath = 10363,
    chromaticWhelp = 10442,
    chromaticDragon = 10447,
    blackhandHandler = 10742,
    rookeryGuardian = 10258,
    rookeryHatcher = 10683,
}

/// Objects of the spire.
enum : uint
{
    emberseerIn = 175244,
    emberseerDoors = 175705,
    emberseerOut = 175153,
    fatherFlame = 175245,
    gythEntryDoor = 164726,
    gythCombatDoor = 175185,
    gythExitDoor = 175186,
    drakkisathDoor1 = 175946,
    drakkisathDoor2 = 175947,
    dragonspine = 164725,
    brazier1 = 175528, // six: 175528 to 175533
    emberseerRune1 = 175266, // seven: 175266 to 175272
}

/// The rune rooms' runes, rooms 1 to 7.
static immutable uint[7] roomRunes = [175197, 175199, 175195, 175200, 175198, 175196, 175194];

/// Which way an encounter has gone.
enum Fight : ubyte { notStarted, inProgress, done, failed }

/// What the spire remembers (`instance.data`).
@instance("instance_blackrock_spire")
struct BlackrockSpire
{
    /// Signals: the area triggers (`value` 1 for UBRS: the player carries the seal), the Father Flame,
    /// Emberseer's freedom, Gyth's half health and Rend's fall from his back.
    enum Signals : uint
    {
        enterUpper = 100, stadiumTrigger = 101, beastIntro = 102, beastAggro = 103, fatherFlameUsed = 104,
        emberseerFree = 105, gythHalf = 106,
    }
    enum uint altarEvent = 4884; /// event_spell_altar_emberseer
    enum uint sealOfAscension = 12344;
    enum : int
    {
        sayNefIntro1 = -1229004, sayNefIntro2 = -1229005, sayNefLose = -1229014, sayRendAttack = -1229015,
        sayNefWarchief = -1229016, sayNefVictory = -1229018, sayNefBuffGyth = -1229017, sayRookeryStart = -1229020,
        sayNefTaunt1 = -1229006,
    }
    enum uint factionBlackDragon = 103;

    static immutable Location dragonsSpawn = Location(210.00f, -420.30f, 110.94f, 3.14f);
    static immutable Location gythSpawn = Location(210.14f, -397.54f, 111.1f, 0);
    static immutable Location stadiumCenter = Location(163.62f, -420.33f, 110.47f, 0);
    static immutable Location nefariusSpawn = Location(164.63f, -444.04f, 121.97f, 3.22f);
    static immutable Location rendSpawn = Location(161.01f, -443.73f, 121.97f, 6.26f);
    static immutable Location rendLeaves = Location(165.74f, -466.46f, 116.80f, 0);
    static immutable Location rookerySpawn = Location(51.11098f, -266.0549f, 92.87846f);
    static immutable Location[3] beastLocs = [
        Location(98.09f, -563.45f, 109.86f, 2.37f), Location(99.81f, -561.47f, 109.24f, 2.43f),
        Location(96.92f, -560.98f, 110.18f, 2.43f),
    ];
    static immutable uint[5][7] stadiumWaves = [
        [chromaticWhelp, chromaticWhelp, chromaticWhelp, chromaticDragon, 0],
        [chromaticWhelp, chromaticWhelp, chromaticWhelp, chromaticDragon, 0],
        [chromaticWhelp, chromaticWhelp, chromaticDragon, blackhandHandler, 0],
        [chromaticWhelp, chromaticWhelp, chromaticDragon, blackhandHandler, 0],
        [chromaticWhelp, chromaticWhelp, chromaticWhelp, chromaticDragon, blackhandHandler],
        [chromaticWhelp, chromaticWhelp, chromaticDragon, chromaticDragon, blackhandHandler],
        [chromaticWhelp, chromaticWhelp, chromaticDragon, chromaticDragon, blackhandHandler],
    ];

    bool upperDoorOpened, roomsSorted;
    ubyte dragonspineStep;
    Fight rooms, emberseerFight, flamewreath, stadium;
    Pack!12[7] roomMobs;
    bool[7] roomDone;
    ubyte flamewreathWave, stadiumWave, stadiumDialogue;
    Pack!8 stadiumMobs;
    EntityRef nefariusRef, rendRef, gythRef, stadiumPlayer;
    bool beastIntroDone, beastOut;

    @transient EntityRef[7] runes;
    @transient EntityRef[7] emberseerRunes;
    @transient EntityRef[6] braziers;
    @transient EntityRef dragonspineDoor, emberseerInDoor, emberseerDoorsRef, emberseerOutDoor, gythEntry, gythCombat,
        gythExit, drakkisath1, drakkisath2, emberseerRef, beastRef;
    @transient Pack!48 roomCandidates;
    @transient Pack!8 incarcerators;
    @transient bool emberseerRecovering, emberseerRunesLit;

    enum Step : ubyte { dragonspine, flamewreathWave, stadium, combatDoorClose }
    Schedule!(Step, 4) steps;
    @transient bool rookeryRecovering, stadiumRecovering, beastRecovering;
    @transient EntityRef[] recoveredOpponents;

    void on(ref InstanceContext brs, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        foreach (i, rune; roomRunes)
            if (entry == rune)
            {
                runes[i] = e.object;
                if (roomDone[i])
                    brs.door(e.object, false);
            }
        if (entry >= emberseerRune1 && entry < emberseerRune1 + 7)
        {
            emberseerRunes[entry - emberseerRune1] = e.object;
            if (emberseerFight == Fight.done || emberseerRunesLit)
                brs.door(e.object, true);
        }
        if (entry >= brazier1 && entry < brazier1 + 6)
        {
            braziers[entry - brazier1] = e.object;
            if (upperDoorOpened)
                brs.door(e.object, true);
        }
        switch (entry)
        {
        case dragonspine:
            dragonspineDoor = e.object;
            if (upperDoorOpened)
                brs.door(e.object, true);
            break;
        case emberseerIn:
            emberseerInDoor = e.object;
            if (rooms == Fight.done)
                brs.door(e.object, true);
            break;
        case emberseerDoors:
            emberseerDoorsRef = e.object;
            if (emberseerFight != Fight.notStarted)
                brs.door(e.object, emberseerFight != Fight.inProgress);
            break;
        case emberseerOut:
            emberseerOutDoor = e.object;
            if (emberseerFight == Fight.done)
                brs.door(e.object, true);
            break;
        case gythEntryDoor:
            gythEntry = e.object;
            if (stadium != Fight.notStarted)
                brs.door(e.object, stadium != Fight.inProgress);
            break;
        case gythCombatDoor:
            gythCombat = e.object;
            if (stadium == Fight.inProgress)
                brs.door(e.object, steps.pending(Step.combatDoorClose));
            break;
        case gythExitDoor:
            gythExit = e.object;
            if (stadium == Fight.done)
                brs.door(e.object, true);
            break;
        case drakkisathDoor1, drakkisathDoor2:
            (entry == drakkisathDoor1 ? drakkisath1 : drakkisath2) = e.object;
            if (brs.entryKilled(drakkisath))
                brs.door(e.object, true);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext brs, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case blackhandSummoner, blackhandVeteran: roomCandidates.add(e.creature); break;
        case incarcerator: incarcerators.add(e.creature); break;
        case emberseer:
            emberseerRef = e.creature;
            if (emberseerRecovering && emberseerIsFree(brs))
                setEmberseerRunes(brs, true);
            break;
        case theBeast: beastRef = e.creature; break;
        case solakar, rookeryGuardian, rookeryHatcher:
            if (rookeryRecovering)
                recoveredOpponents ~= e.creature;
            break;
        case chromaticWhelp, chromaticDragon, blackhandHandler, gyth:
            if (stadiumRecovering)
                recoveredOpponents ~= e.creature;
            break;
        case rend:
            // Rend, knocked off Gyth's back, joins the fight: the stadium counts him.
            if (stadium == Fight.inProgress && stadiumWave > 7 && e.creature != rendRef)
            {
                if (stadiumRecovering)
                    recoveredOpponents ~= e.creature;
                stadiumMobs.add(e.creature);
                brs.checkpointCreature(e.creature);
            }
            break;
        default: break;
        }
    }

    void on(ref InstanceContext brs, const ref Restored e)
    {
        // A defender's death reaches the database as it happens, the rooms' state with the next save.
        if (rooms == Fight.inProgress)
        {
            foreach (ref room; roomMobs)
            {
                EntityRef[] dead;
                foreach (who; room)
                    if (brs.killed(who))
                        dead ~= who;
                foreach (who; dead)
                    room.died(who);
            }
            settleRooms(brs);
        }
        if (emberseerFight == Fight.inProgress)
        {
            if (brs.entryKilled(emberseer))
                finishEmberseer(brs);
            else if (brs.hasSavedCreature(emberseer))
            {
                emberseerRecovering = true;
                brs.waitForPlayer();
            }
            else
                emberseerFight = Fight.failed;
        }
        if (flamewreath == Fight.inProgress)
        {
            if (steps.pending(Step.flamewreathWave) || brs.hasSavedCreature(solakar))
            {
                rookeryRecovering = true;
                brs.waitForPlayer();
            }
            else
                flamewreath = Fight.failed; // Older saves did not keep Solakar.
        }
        if (stadium == Fight.inProgress)
        {
            if (brs.hasSavedCreature(nefarius))
            {
                stadiumRecovering = true;
                brs.waitForPlayer();
            }
            else
                failStadium(brs); // Older saves did not keep the stadium actors.
        }
        if (beastIntroDone || beastOut)
        {
            beastRecovering = brs.hasSavedCreature(theBeast);
            if (beastRecovering || brs.hasSavedCreature(blackhandElite))
                brs.waitForPlayer();
            if (beastOut && !beastRecovering && !brs.entryKilled(theBeast))
                beastOut = false;
        }
    }

    void on(ref InstanceContext brs, const ref PlayerEntered e)
    {
        if (emberseerRecovering)
        {
            emberseerRecovering = false;
            if (emberseerIsFree(brs) && !brs.alive(brs.victimOf(emberseerRef)))
                brs.attack(emberseerRef, e.player);
            foreach (guard; incarcerators)
                if (brs.alive(guard) && !brs.alive(brs.victimOf(guard)))
                    brs.attack(guard, e.player);
        }
        if (beastRecovering && beastOut && brs.alive(beastRef) && !brs.alive(brs.victimOf(beastRef)))
            brs.attack(beastRef, e.player);
        beastRecovering = false;
        rookeryRecovering = stadiumRecovering = false;
        foreach (creature; recoveredOpponents)
            if (brs.alive(creature) && !brs.alive(brs.victimOf(creature)))
                brs.attack(creature, e.player);
        recoveredOpponents = null;
    }

    void on(ref InstanceContext brs, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.enterUpper:
            if (e.value == 1 && !upperDoorOpened)
            {
                upperDoorOpened = true;
                dragonspineStep = 0;
                steps.after(Step.dragonspine, 100.msecs);
            }
            sortRoomMobs(brs);
            break;
        case Signals.stadiumTrigger:
            if (stadium == Fight.notStarted || stadium == Fight.failed)
                startStadium(brs, e.from);
            break;
        case Signals.beastIntro, Signals.beastAggro:
            if (!beastIntroDone)
            {
                beastIntroDone = true;
                foreach (at; beastLocs)
                    if (const ambusher = brs.summon(blackhandElite, at, 0, e.from))
                        brs.checkpointCreature(ambusher);
                brs.checkpoint();
            }
            if (e.id == Signals.beastAggro && !beastOut && beastRef)
            {
                beastOut = true;
                brs.attack(beastRef, e.from);
                brs.checkpointCreature(beastRef);
            }
            break;
        case Signals.fatherFlameUsed:
            if (flamewreath == Fight.notStarted || flamewreath == Fight.failed)
            {
                flamewreath = Fight.inProgress;
                flamewreathWave = 0;
                steps.after(Step.flamewreathWave, 1.msecs);
                brs.checkpoint();
            }
            break;
        case Signals.emberseerFree:
            setEmberseerRunes(brs, true);
            brs.checkpoint();
            break;
        case Signals.gythHalf:
            if (nefariusRef && gythRef)
            {
                brs.castSpell(nefariusRef, 16337, gythRef); // Chromatic Chaos
                brs.say(nefariusRef, sayNefBuffGyth);
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext brs, const ref EventHappened e)
    {
        if (e.event != altarEvent)
            return;
        brs.consume();
        if (emberseerFight == Fight.done || emberseerFight == Fight.inProgress || !emberseerRef)
            return;
        brs.signal(emberseerRef, Emberseer.Signals.grow);
        foreach (who; incarcerators)
            brs.unitFlags(who, UnitFlag.immuneToPlayer | UnitFlag.immuneToNpc, false);
    }

    void on(ref InstanceContext brs, const ref CreatureEngaged e)
    {
        if (e.creature.entry == theBeast)
        {
            beastOut = true;
            brs.checkpointCreature(e.creature);
        }
        if (e.creature.entry == incarcerator && emberseerFight != Fight.inProgress && emberseerFight != Fight.done)
        {
            emberseerFight = Fight.inProgress;
            if (emberseerDoorsRef)
                brs.door(emberseerDoorsRef, false);
            if (emberseerRef && brs.alive(emberseerRef))
                brs.checkpointCreature(emberseerRef);
            foreach (guard; incarcerators)
                if (brs.alive(guard))
                    brs.checkpointCreature(guard);
        }
    }

    void on(ref InstanceContext brs, const ref CreatureEvaded e)
    {
        switch (e.creature.entry)
        {
        case incarcerator, emberseer:
            if (emberseerFight == Fight.inProgress)
            {
                emberseerFight = Fight.failed;
                if (emberseerDoorsRef)
                    brs.door(emberseerDoorsRef, true);
                foreach (who; incarcerators)
                    brs.unitFlags(who, UnitFlag.immuneToPlayer | UnitFlag.immuneToNpc);
                setEmberseerRunes(brs, false);
                if (emberseerRef && e.creature != emberseerRef)
                    brs.signal(emberseerRef, Emberseer.Signals.reset);
                brs.checkpoint();
            }
            break;
        case solakar, rookeryGuardian, rookeryHatcher:
            if (flamewreath == Fight.inProgress)
            {
                flamewreath = Fight.failed;
                steps.cancel(Step.flamewreathWave);
                brs.checkpoint();
            }
            break;
        case theBeast:
            beastOut = false;
            brs.checkpoint();
            break;
        case chromaticWhelp, chromaticDragon, blackhandHandler, gyth, rend:
            if (stadium == Fight.inProgress && (stadiumMobs.has(e.creature) || e.creature == gythRef))
                failStadium(brs);
            break;
        default:
            break;
        }
    }

    /// The rooms whose defenders are all dead have their runes go out; all seven out, the way to Emberseer opens.
    private void settleRooms(ref InstanceContext brs)
    {
        bool allDone = true;
        foreach (i, ref room; roomMobs)
        {
            if (!roomDone[i] && (room.allDead || room.empty))
            {
                roomDone[i] = true;
                if (runes[i])
                    brs.door(runes[i], false); // the rune goes out
            }
            allDone &= roomDone[i];
        }
        if (allDone && rooms != Fight.done)
        {
            rooms = Fight.done;
            brs.log("the seven runes are out: the way to Emberseer opens");
            if (emberseerInDoor)
                brs.door(emberseerInDoor, true);
        }
    }

    void on(ref InstanceContext brs, const ref CreatureDied e)
    {
        incarcerators.died(e.creature);
        switch (e.creature.entry)
        {
        case blackhandSummoner, blackhandVeteran:
            if (rooms != Fight.inProgress)
                break;
            foreach (ref room; roomMobs)
                room.died(e.creature);
            settleRooms(brs);
            break;
        case incarcerator:
            if (emberseerFight == Fight.inProgress)
                brs.checkpoint();
            break;
        case emberseer:
            finishEmberseer(brs);
            break;
        case solakar:
            flamewreath = Fight.done;
            brs.checkpoint();
            break;
        case rookeryGuardian, rookeryHatcher:
            if (flamewreath == Fight.inProgress)
                brs.checkpoint();
            break;
        case drakkisath:
            foreach (door; [drakkisath1, drakkisath2])
                if (door)
                    brs.door(door, true);
            break;
        case theBeast:
            brs.checkpoint();
            break;
        case blackhandElite:
            if (beastIntroDone && !brs.entryKilled(theBeast))
                brs.checkpoint();
            break;
        case chromaticWhelp, chromaticDragon, blackhandHandler, gyth, rend:
            if (stadium != Fight.inProgress || !stadiumMobs.died(e.creature))
                break;
            if (brs.random(100) < 5 && nefariusRef)
                brs.say(nefariusRef, sayNefTaunt1);
            if (stadiumMobs.allDead)
            {
                if (stadiumWave <= 7)
                    steps.after(Step.stadium, 1.msecs);
                else
                {
                    stadiumDialogue = 5; // the victory
                    steps.after(Step.stadium, 1.msecs);
                }
            }
            brs.checkpoint();
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext brs, Step step)
    {
        final switch (step)
        {
        case Step.dragonspine:
            // Two braziers a second, then the door.
            const i = dragonspineStep++;
            if (i < 3)
            {
                foreach (b; [braziers[2 * i], braziers[2 * i + 1]])
                    if (b)
                        brs.door(b, true);
                steps.after(Step.dragonspine, 1.seconds);
            }
            else if (dragonspineDoor)
                brs.door(dragonspineDoor, true);
            break;
        case Step.flamewreathWave:
            flamewreathStep(brs);
            break;
        case Step.stadium:
            stadiumStep(brs);
            break;
        case Step.combatDoorClose:
            if (gythCombat)
                brs.door(gythCombat, false);
            break;
        }
    }

    /// Entering the upper spire for the first time: the Blackhand of each rune room are counted.
    private void sortRoomMobs(ref InstanceContext brs)
    {
        if (roomsSorted)
            return;
        roomsSorted = true;
        Location rune, mob;
        foreach (i, r; runes)
        {
            if (!r || !brs.locationOf(r, rune))
            {
                roomDone[i] = true; // no rune here: nothing to do there
                continue;
            }
            foreach (who; roomCandidates)
                if (brs.locationOf(who, mob) && (mob.x - rune.x) ^^ 2 + (mob.y - rune.y) ^^ 2 + (mob.z - rune.z) ^^ 2 < 100)
                    roomMobs[i].add(who);
        }
        rooms = Fight.inProgress;
    }

    private void setEmberseerRunes(ref InstanceContext brs, bool lit)
    {
        emberseerRunesLit = lit;
        foreach (rune; emberseerRunes)
            if (rune)
                brs.door(rune, lit);
    }

    private bool emberseerIsFree(ref InstanceContext brs)
    {
        return emberseerRef && brs.alive(emberseerRef)
            && !(brs.unitFlagsOf(emberseerRef) & (UnitFlag.uninteractible | UnitFlag.immuneToPlayer));
    }

    private void finishEmberseer(ref InstanceContext brs)
    {
        emberseerFight = Fight.done;
        setEmberseerRunes(brs, true);
        if (emberseerDoorsRef)
            brs.door(emberseerDoorsRef, true);
        if (emberseerOutDoor)
            brs.door(emberseerOutDoor, true);
        brs.checkpoint();
    }

    /// Six waves of rookery guardians and hatchers, then Solakar.
    private void flamewreathStep(ref InstanceContext brs)
    {
        if (flamewreath != Fight.inProgress)
            return;
        const target = brs.anyPlayer();
        if (flamewreathWave < 6)
        {
            EntityRef last;
            foreach (_; 0 .. 2)
            {
                Location at = rookerySpawn;
                at.x += (cast(int) brs.random(5) - 2);
                at.y += (cast(int) brs.random(5) - 2);
                last = brs.summon(brs.random(2) && flamewreathWave ? rookeryGuardian : rookeryHatcher, at, 300_000, target);
                if (last)
                    brs.checkpointCreature(last);
            }
            if (flamewreathWave == 0 && last)
                brs.say(last, sayRookeryStart);
            const wave = flamewreathWave++;
            steps.after(Step.flamewreathWave, (wave < 4 ? 30 : 40).seconds); // ScriptDev2: 30 s, the last two 40 s
        }
        else
        {
            if (const boss = brs.summon(solakar, rookerySpawn, 3_600_000, target))
                brs.checkpointCreature(boss);
            else
            {
                flamewreath = Fight.failed;
                brs.checkpoint();
            }
            steps.cancel(Step.flamewreathWave);
        }
    }

    private void startStadium(ref InstanceContext brs, EntityRef player)
    {
        stadium = Fight.inProgress;
        stadiumPlayer = player;
        stadiumWave = 0;
        stadiumDialogue = 0;
        stadiumMobs.clear();
        nefariusRef = brs.summon(nefarius, nefariusSpawn);
        if (nefariusRef)
        {
            brs.setFaction(nefariusRef, factionBlackDragon);
            brs.checkpointCreature(nefariusRef);
        }
        rendRef = brs.summon(rend, rendSpawn);
        if (rendRef)
        {
            brs.unitFlags(rendRef, UnitFlag.immuneToPlayer);
            brs.checkpointCreature(rendRef);
        }
        if (gythEntry)
            brs.door(gythEntry, false);
        steps.after(Step.stadium, 1.seconds);
        brs.checkpoint();
    }

    /// The stadium: Nefarius's words, seven waves, Gyth, and the end.
    private void stadiumStep(ref InstanceContext brs)
    {
        if (stadium != Fight.inProgress)
            return;
        if (stadiumDialogue < 2)
        {
            if (nefariusRef)
                brs.say(nefariusRef, stadiumDialogue == 0 ? sayNefIntro1 : sayNefIntro2);
            steps.after(Step.stadium, (stadiumDialogue++ == 0 ? 7 : 5).seconds);
            return;
        }
        if (stadiumDialogue == 5)
        {
            // Victory: Nefarius leaves; the way on opens.
            stadium = Fight.done;
            if (nefariusRef)
            {
                brs.say(nefariusRef, sayNefVictory);
                brs.despawn(nefariusRef, 5000);
            }
            if (gythEntry)
                brs.door(gythEntry, true);
            if (gythExit)
                brs.door(gythExit, true);
            brs.checkpoint();
            return;
        }
        if (stadiumWave < 7)
        {
            stadiumMobs.clear();
            foreach (entry; stadiumWaves[stadiumWave])
                if (entry)
                {
                    Location at = dragonsSpawn;
                    at.x -= brs.random(7);
                    at.y += cast(int) brs.random(15) - 7;
                    if (const made = brs.summon(entry, at, 0, stadiumPlayer && brs.alive(stadiumPlayer) ? stadiumPlayer : brs.anyPlayer()))
                    {
                        stadiumMobs.add(made);
                        brs.checkpointCreature(made);
                    }
                }
            openCombatDoor(brs);
            ++stadiumWave;
            steps.after(Step.stadium, 60.seconds);
            return;
        }
        if (stadiumWave == 7)
        {
            // Nefarius loses patience; Rend rides out on Gyth.
            ++stadiumWave;
            if (nefariusRef)
                brs.say(nefariusRef, sayNefLose);
            if (rendRef)
            {
                brs.say(rendRef, sayRendAttack);
                brs.moveTo(rendRef, rendLeaves, 0, true);
                brs.despawn(rendRef, 5000);
                brs.releaseCheckpointActor(rendRef); // gone for good: a crash before he leaves does not bring him back
            }
            if (nefariusRef)
                brs.say(nefariusRef, sayNefWarchief);
            stadiumMobs.clear();
            gythRef = brs.summon(gyth, gythSpawn, 0, stadiumPlayer && brs.alive(stadiumPlayer) ? stadiumPlayer : brs.anyPlayer());
            if (gythRef)
            {
                stadiumMobs.add(gythRef);
                brs.checkpointCreature(gythRef);
            }
            openCombatDoor(brs);
        }
    }

    private void openCombatDoor(ref InstanceContext brs)
    {
        if (gythCombat)
        {
            brs.door(gythCombat, true);
            steps.after(Step.combatDoorClose, 5.seconds);
        }
    }

    private void failStadium(ref InstanceContext brs)
    {
        stadium = Fight.failed;
        steps.cancel(Step.stadium);
        steps.cancel(Step.combatDoorClose);
        foreach (who; [nefariusRef, rendRef, gythRef])
            if (who)
                brs.despawn(who);
        foreach (mob; stadiumMobs)
            brs.despawn(mob);
        stadiumMobs.clear();
        nefariusRef = rendRef = gythRef = EntityRef.init;
        if (gythEntry)
            brs.door(gythEntry, true);
        brs.checkpoint();
    }
}

/// The spire's area triggers: the way to the upper spire, the stadium, The Beast's lair.
@areaTrigger("at_blackrock_spire")
struct AtBlackrockSpire
{
    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        switch (e.trigger)
        {
        case 2046:
            at.signalDungeon(BlackrockSpire.Signals.enterUpper, at.hasItem(e.player, BlackrockSpire.sealOfAscension) ? 1 : 0);
            break;
        case 2026: at.signalDungeon(BlackrockSpire.Signals.stadiumTrigger); break;
        case 2067: at.signalDungeon(BlackrockSpire.Signals.beastIntro); break;
        case 2066: at.signalDungeon(BlackrockSpire.Signals.beastAggro); break;
        default: break;
        }
    }
}

/// The Father Flame: used, the rookery's waves begin.
@gameObject("go_father_flame")
struct FatherFlame
{
    void on(ref GameObjectContext flame, const ref ObjectUsed e)
    {
        flame.signalDungeon(BlackrockSpire.Signals.fatherFlameUsed);
    }
}

/**
 * Pyroguard Emberseer: held by his incarcerators; woken at his altar, he grows (twenty stacks) and
 * breaks free to fight: fire nova, flame buffet, pyroblast.
 */
@creature("boss_pyroguard_emberseer")
struct Emberseer
{
    enum Signals : uint { grow = 1, reset = 2 }
    enum : int { emoteNear = -1229001, emoteFull = -1229002, sayFree = -1229003, emoteBegin = -1229000 }
    enum : uint
    {
        fireShield = 13377, fullStrength = 16047, growing = 16048, bonusDamage = 16534, transform = 16052,
        fireNova = 23462, flameBuffet = 23341, pyroblast = 20228,
    }

    enum Step : ubyte { grow, nova, buffet, pyroblast }
    Schedule!Step steps;
    ubyte stacks;
    bool growingNow, free;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        hold(me);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.grow && !growingNow && !free)
        {
            growingNow = true;
            me.say(emoteBegin);
            me.castSelf(growing, true);
            steps.every(Step.grow, 1500.msecs);
        }
        else if (e.id == Signals.reset && !me.inCombat)
            hold(me);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!free)
            return;
        steps.after(Step.nova, 6.seconds);
        steps.after(Step.buffet, 3.seconds);
        steps.after(Step.pyroblast, 14.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.grow:
            ++stacks;
            if (stacks == 10)
                me.say(emoteNear);
            else if (stacks >= 20)
            {
                steps.cancel(Step.grow);
                free = true;
                me.say(emoteFull);
                me.say(sayFree);
                foreach (spell; [fullStrength, bonusDamage, transform])
                    me.castSelf(spell, true);
                me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer, false);
                me.signalDungeon(BlackrockSpire.Signals.emberseerFree);
                if (const enemy = me.playerNearby(60))
                    me.attack(enemy);
            }
            break;
        case Step.nova:
            me.castSelf(fireNova);
            steps.after(Step.nova, 6.seconds);
            break;
        case Step.buffet:
            me.castSelf(flameBuffet);
            steps.after(Step.buffet, 14.seconds);
            break;
        case Step.pyroblast:
            if (const target = me.randomTarget())
                me.castSpell(pyroblast, target);
            steps.after(Step.pyroblast, 15.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        hold(me);
    }

    private void hold(ref CreatureContext me)
    {
        steps.clear();
        stacks = 0;
        growingNow = free = false;
        me.unitFlags(UnitFlag.uninteractible | UnitFlag.immuneToPlayer);
        me.castSelf(fireShield, true);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/**
 * Gyth: corrosive acid, freeze, flame breath, knock away; Nefarius strengthens him at half health;
 * near death Rend is knocked off his back and fights on foot.
 */
@creature("boss_gyth")
struct Gyth
{
    enum int emoteKnockedOff = -1229019;
    enum : uint { rendMounts = 16167, corrosiveAcid = 16359, freeze = 16350, flameBreath = 16390, knockAway = 10101 }

    enum Step : ubyte { acid, freeze, breath, knock }
    Schedule!Step steps;
    bool rendDown, chaos;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
        me.castSelf(rendMounts, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.acid, 8.seconds);
        steps.after(Step.freeze, 11.seconds);
        steps.after(Step.breath, 4.seconds);
        steps.after(Step.knock, 23.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!chaos && e.after < 50)
        {
            chaos = true;
            me.signalDungeon(BlackrockSpire.Signals.gythHalf);
        }
        if (!rendDown && e.after < 11)
        {
            rendDown = true;
            me.deathPrevention(false);
            me.removeAura(me.self, rendMounts);
            me.summon(rend, me.location, 0, me.victim);
            me.say(emoteKnockedOff);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.acid:
            me.castSelf(corrosiveAcid);
            steps.after(Step.acid, 7.seconds);
            break;
        case Step.freeze:
            me.castSelf(freeze);
            steps.after(Step.freeze, 16.seconds);
            break;
        case Step.breath:
            me.castSelf(flameBreath);
            steps.after(Step.breath, 10_500.msecs);
            break;
        case Step.knock:
            me.castSpell(knockAway);
            steps.after(Step.knock, 23.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// Overlord Wyrmthalak: blast wave, shout, cleave, knock away; at half health two guards come running.
@creature("boss_overlord_wyrmthalak")
struct Wyrmthalak
{
    enum : uint { blastWave = 11130, shout = 23511, cleave = 20691, knockAway = 20686 }
    static immutable uint[3] guards = [9583, 9268, 9216];
    static immutable Location[2] guardSpawns = [Location(-51.6805f, -439.831f, 78.2874f, 4.657f), Location(-54.4554f, -439.679f, 78.2884f, 4.657f)];

    enum Step : ubyte { blastWave, shout, cleave, knock }
    Schedule!Step steps;
    bool summoned;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.blastWave, 20.seconds);
        steps.after(Step.shout, 2.seconds);
        steps.after(Step.cleave, 6.seconds);
        steps.after(Step.knock, 12.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!summoned && e.after < 51)
        {
            summoned = true;
            foreach (at; guardSpawns)
            {
                const target = me.randomTarget();
                me.summon(guards[me.random(3)], at, 300_000, target ? target : me.victim);
            }
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.blastWave:
            me.castSelf(blastWave);
            steps.after(Step.blastWave, 20.seconds);
            break;
        case Step.shout:
            me.castSelf(shout);
            steps.after(Step.shout, 10.seconds);
            break;
        case Step.cleave:
            me.castSpell(cleave);
            steps.after(Step.cleave, 7.seconds);
            break;
        case Step.knock:
            me.castSelf(knockAway);
            steps.after(Step.knock, 14.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        summoned = false;
    }
}

/// A Rookery Hatcher: strikes, sunders armor, and stirs the eggs of the rookery.
@creature("npc_rookery_hatcher")
struct RookeryHatcher
{
    enum : uint { strike = 15580, sunderArmor = 15572, disturbEggs = 15746 }

    enum Step : ubyte { strike, sunder, eggs }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.strike, (5000 + me.random(2000)).msecs);
        steps.after(Step.sunder, 5.seconds);
        steps.after(Step.eggs, (8000 + me.random(2000)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.strike:
            me.castSpell(strike);
            steps.after(Step.strike, (4000 + me.random(2000)).msecs);
            break;
        case Step.sunder:
            me.castSpell(sunderArmor);
            steps.after(Step.sunder, 5.seconds);
            break;
        case Step.eggs:
            me.castSelf(disturbEggs);
            steps.after(Step.eggs, (7500 + me.random(2500)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// The altar of Emberseer used (`event_spell_altar_emberseer`): the dungeon's script wakes the incarcerators
/// and Emberseer (`EventHappened`); the event's own script lets it through to it.
@scriptedEvent("event_spell_altar_emberseer")
struct EmberseerAltarEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackrockspire;
    auto brs = runInstance!self("instance_blackrock_spire");
    foreach (i; 0 .. 6)
        brs.raise(ObjectLoaded(objectRef(brazier1 + i)));
    brs.raise(ObjectLoaded(objectRef(dragonspine)));
    brs.raise(ObjectLoaded(objectRef(emberseerIn)));
    brs.raise(ObjectLoaded(objectRef(roomRunes[0])));
    brs.raise(CreatureLoaded(creatureRef(blackhandSummoner, 1)));
    brs.raise(CreatureLoaded(creatureRef(blackhandVeteran, 2)));
    brs.raise(Signal(playerRef, BlackrockSpire.Signals.enterUpper, 0));
    brs.run(5000);
    assert(!brs.host.done("door 164725 open"), "no seal: no door");
    brs.raise(Signal(playerRef, BlackrockSpire.Signals.enterUpper, 1));
    brs.run(5000);
    assert(brs.host.done("door 175533 open") && brs.host.done("door 164725 open"));
    brs.raise(CreatureDied(creatureRef(blackhandSummoner, 1)));
    assert(!brs.host.done("door 175244 open"));
    brs.raise(CreatureDied(creatureRef(blackhandVeteran, 2)));
    assert(brs.host.done("door 175197 closed") && brs.host.done("door 175244 open"), "the rune out, the way open");

    // The stadium: seven waves, then Gyth.
    brs.raise(Signal(playerRef, BlackrockSpire.Signals.stadiumTrigger));
    assert(brs.host.done("summon 10162") && brs.host.done("summon 10429"));
    brs.run(13_000);
    assert(brs.host.times("summon 10442") == 3);
    foreach (wave; 0 .. 7)
    {
        foreach (spawn; brs.host.spawned - 4 .. brs.host.spawned + 1)
            foreach (entry; [chromaticWhelp, chromaticDragon, blackhandHandler])
                brs.raise(CreatureDied(creatureRef(entry, 1000 + spawn)));
        brs.run(500);
    }
    assert(brs.host.done("summon 10339"), "Gyth comes");
    brs.raise(CreatureDied(creatureRef(gyth, 1000 + brs.host.spawned)));
    brs.run(500);
    assert(brs.host.done("say 10162 -1229018") && brs.state!BlackrockSpire.stadium == Fight.done);
}

// A crash between a rune room defender's death and the save after it: the copy comes back with the room's last
// defender dead among its spawns but alive in its state, and the rune goes out all the same.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.blackrockspire;
    auto brs = runInstance!self("instance_blackrock_spire");
    brs.raise(ObjectLoaded(objectRef(emberseerIn)));
    brs.raise(ObjectLoaded(objectRef(roomRunes[0])));
    brs.raise(CreatureLoaded(creatureRef(blackhandSummoner, 1)));
    brs.raise(CreatureLoaded(creatureRef(blackhandVeteran, 2)));
    brs.raise(Signal(playerRef, BlackrockSpire.Signals.enterUpper, 1));
    brs.raise(CreatureDied(creatureRef(blackhandSummoner, 1)));
    ByteWriter saved;
    brs.runtime.save(brs.handle, saved); // the last save the copy wrote
    brs.host.dead[creatureRef(blackhandVeteran, 2).guid] = true; // its death, recorded as it happened

    auto after = runInstance!self("instance_blackrock_spire");
    after.host.dead = brs.host.dead;
    auto r = ByteReader(saved.data);
    assert(after.runtime.load(after.handle, r));
    after.raise(Restored());
    after.raise(ObjectLoaded(objectRef(roomRunes[0])));
    after.raise(ObjectLoaded(objectRef(emberseerIn)));
    assert(after.state!BlackrockSpire.rooms == Fight.done && after.host.done("door 175244 open"),
        "the dead defender counts: the way to Emberseer opens");
}
