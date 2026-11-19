/**
 * Dire Maul (map 429): in the east, Old Ironbark redeemed when Zevrim Thornhoof falls, and Alzzin's
 * crumbling wall and corrupted vine (his creature script reports his fight); in the west, the five
 * crystal generators (each goes out when its guards are slain; with all five out the force field
 * around Immol'thar falls and the Highborne summoners turn on him; his death sets Prince
 * Tortheldrin against the players), and the door behind Tendris Warpwood; in the north, King
 * Gordok's death, which makes Kromcrush and Cho'Rush friendly and brings Mizzle the Crafty for the
 * tribute, and the Fixed Trap that holds Guard Slip'kik when he walks into it.
 *
 * The Dreadsteed of Xoroth (the warlocks' epic mount): Release J'eevee (`event_spells_warlock_dreadsteed`)
 * brings the ritual's keeper (`npc_warlock_mount_ritual`) and J'eevee, who sets out the Bell of Dethmoora,
 * the Wheel of the Black March and the Doomsday Candle (`go_dreadsteed_quest_objects`); while the players
 * keep them going (each blesses its last user every six seconds; the keeper puts one out every 30 to 45
 * seconds) nine waves of demons come through the portals; then the circle is ready, and the Dreadsteed may
 * be summoned. All three out, or nobody left, and the ritual fails.
 */
module dmangos.scripts.diremaul;

import dmangos.script;

/// Creatures of Dire Maul.
enum : uint
{
    zevrim = 11490,
    oldIronbark = 11491,
    ironbarkRedeemed = 14241,
    tendris = 11489,
    prince = 11486,
    immolthar = 11496,
    arcaneAberration = 11480,
    manaRemnant = 11483,
    highborneSummoner = 11466,
    kingGordok = 11501,
    kromcrush = 14325,
    chorush = 14324,
    mizzle = 14353,
    jeevee = 14500,
    ritualKeeper = 14501,
    xorothianImp = 14482,
    dreadGuard = 14483,
    lordHelnurath = 14506,
    guardSlipkik = 14323,
}

/// Objects of Dire Maul.
enum : uint
{
    crumbleWall = 177220,
    corruptVine = 179502,
    felvineShard = 179559,
    conservatoryDoor = 176907,
    forcefield = 179503,
    warpwoodDoor = 177221,
    bellOfDethmoora = 179674,
    wheelOfBlackMarch = 179672,
    doomsdayCandle = 179673,
    ritualCircle = 179668,
    dreadsteedPortal = 179681,
    fixedTrap = 179512,
}

/// The ritual's three objects, and what each blesses its user with.
static immutable uint[3] ritualObjects = [bellOfDethmoora, wheelOfBlackMarch, doomsdayCandle];
static immutable uint[3] ritualBlessings = [23117, 23120, 23226];
/// The nine symbols lit one with each wave (their spawns' order), and their entries.
static immutable Location[9] ritualSymbols = [
    Location(-25.8848f, 798.921f, -29.5358f), Location(-28.8647f, 828.021f, -29.5358f), Location(-57.1792f, 812.96f, -29.5358f),
    Location(-37.3899f, 793.225f, -29.5358f), Location(-21.8534f, 820.043f, -29.5358f), Location(-50.8857f, 826.376f, -29.5358f),
    Location(-53.5593f, 801.216f, -29.5358f), Location(-20.693f, 807.962f, -29.5358f), Location(-38.9241f, 831.486f, -29.5358f),
];
static immutable uint[3] ritualSymbolEntries = [179669, 179670, 179671];
/// Where the keeper and J'eevee come, and the pedestal the demons go for.
static immutable ritualPlace = Location(-37.9392f, 812.805f, -29.4525f, 4.81711f);
static immutable ritualPedestal = Location(-38.5f, 811.8f, -29.5f);

/// The five crystal generators, and where they stand.
static immutable uint[5] generators = [177259, 177257, 177258, 179504, 179505];
static immutable Location[5] generatorPlaces = [
    Location(12.9412f, 277.931f, -8.93289f), Location(-92.3458f, 442.67f, 28.547f), Location(121.222f, 429.092f, 28.4548f),
    Location(78.1384f, 737.402f, -24.6216f), Location(-155.434f, 734.166f, -24.6216f),
];

/// What Dire Maul remembers (`instance.data`).
@instance("instance_dire_maul")
struct DireMaul
{
    /// Alzzin's `creature_ai_scripts` set "instance data 0": 4 (special) at half health, 3 (done) as he dies.
    enum Signals : uint
    {
        alzzin = 0,
        ritualStart = 100,      /// the keeper: the circle and the portals come
        ritualWave = 101,       /// the keeper: wave `value` (1 to 9) comes; its symbol lights
        ritualDeactivate = 102, /// the keeper: one of the three objects goes out
        ritualEnd = 103,        /// the keeper: the waves are over; the circle is ready
    }
    /// The ritual's events: J'eevee released, the Dreadsteed summoned.
    enum uint releaseJeeveeEvent = 8420, summonDreadsteedEvent = 8428;
    enum : int { sayUnsummonDemon = -1429005, saySlipkikTrap = -1429004 }
    enum uint teleportOut = 29216, iceLock = 22856;
    /// How the Dreadsteed's ritual stands (forgotten with a restart, as CMaNGOS forgets one under way).
    enum Ritual : ubyte { notStarted, inProgress, complete, done, failed }
    enum : int { sayFreeImmolthar = -1429000, sayKillImmolthar = -1429001, sayIronbarkRedeem = -1429002, sayChorushKingDead = -1429003 }
    enum : uint { factionHostile = 14, factionFriendly = 35 }
    static immutable Location mizzleSpawn = Location(683.296f, 484.384f, 29.544f, 0.0174f);

    bool zevrimDead, wallDown, alzzinDead, warpwoodDead, immoltharDead, gordokDead, guardsSorted;
    bool[5] pylonDone;
    Pack!12[5] pylonGuards;
    @transient EntityRef[5] generatorRefs;
    @transient EntityRef wall, vine, conservatory, field, warpDoor, ironbarkRef, princeRef, immoltharRef, kromcrushRef, chorushRef;
    @transient Pack!48 guardCandidates;
    @transient Pack!24 summoners;

    // The Dreadsteed's ritual.
    @transient Ritual ritual;
    @transient bool[3] ritualActive;
    @transient EntityRef[3] ritualUser, ritualObjectRefs;
    @transient EntityRef keeperRef, jeeveeRef, circleRef, trapRef;
    @transient Pack!64 demons;
    @transient Pack!32 scenery; /// the portals and symbols the ritual lit

    enum Step : ubyte { ritualCheck, ritualPulse, trap }
    Schedule!(Step, 4) steps;

    void on(ref InstanceContext dm, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        foreach (i, g; generators)
            if (entry == g)
            {
                generatorRefs[i] = e.object;
                if (pylonDone[i])
                    dm.door(e.object, true);
            }
        switch (entry)
        {
        case crumbleWall:
            wall = e.object;
            if (wallDown || alzzinDead)
                dm.door(e.object, true);
            break;
        case corruptVine:
            vine = e.object;
            if (alzzinDead)
                dm.door(e.object, true);
            break;
        case conservatoryDoor: conservatory = e.object; break;
        case forcefield:
            field = e.object;
            if (allPylonsDone)
                dm.door(e.object, true);
            break;
        case warpwoodDoor:
            warpDoor = e.object;
            if (warpwoodDead)
                dm.door(e.object, true);
            break;
        case bellOfDethmoora, wheelOfBlackMarch, doomsdayCandle:
            // J'eevee sets them out (and starts them) during the ritual; at any other time they are not there.
            foreach (i, o; ritualObjects)
                if (o == entry)
                {
                    ritualObjectRefs[i] = e.object;
                    ritualActive[i] = ritual == Ritual.inProgress;
                }
            if (ritual != Ritual.inProgress)
                dm.despawnObject(e.object);
            break;
        case ritualCircle: circleRef = e.object; break;
        case dreadsteedPortal, 179669, 179670, 179671: scenery.add(e.object); break;
        case fixedTrap:
            trapRef = e.object;
            steps.every(Step.trap, 250.msecs);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext dm, const ref EventHappened e)
    {
        if (e.event == releaseJeeveeEvent)
        {
            if (ritual != Ritual.notStarted && ritual != Ritual.failed)
                return dm.consume();
            // The keeper brings J'eevee and runs the ritual; the event's database script has J'eevee speak.
            ritual = Ritual.inProgress;
            ritualActive[] = false;
            ritualUser[] = e.source;
            demons.clear();
            scenery.clear();
            dm.summon(ritualKeeper, ritualPlace);
            steps.every(Step.ritualCheck, 1.seconds);
            steps.every(Step.ritualPulse, 6.seconds);
        }
        else if (e.event == summonDreadsteedEvent)
        {
            if (ritual != Ritual.complete)
                return dm.consume(); // no Dreadsteed before the ritual is over
            ritual = Ritual.done; // the database script brings his portal and the Dreadsteed
        }
    }

    void on(ref InstanceContext dm, const ref ObjectUsedHere e)
    {
        foreach (i, o; ritualObjectRefs)
            if (o && o == e.object)
            {
                ritualActive[i] = true;
                ritualUser[i] = e.player;
            }
    }

    void on(ref InstanceContext dm, Step step)
    {
        final switch (step)
        {
        case Step.ritualCheck:
            if (ritual != Ritual.inProgress)
                return steps.cancel(Step.ritualCheck);
            if (jeeveeRef && dm.alive(jeeveeRef))
            {
                if (dm.playerCount == 0)
                    failRitual(dm);
            }
            else if (ritualObjectRefs[0] && ritualObjectRefs[1] && ritualObjectRefs[2]
                && !ritualActive[0] && !ritualActive[1] && !ritualActive[2])
                failRitual(dm);
            break;
        case Step.ritualPulse:
            if (ritual != Ritual.inProgress)
                return steps.cancel(Step.ritualPulse);
            foreach (i; 0 .. 3)
                if (ritualActive[i] && ritualUser[i] && keeperRef)
                    dm.castSpell(keeperRef, ritualBlessings[i], ritualUser[i]);
            break;
        case Step.trap:
            // Guard Slip'kik walks into the Fixed Trap: it holds him, and he will not fight players.
            Location at;
            EntityRef[1] slipkik;
            if (!trapRef || !dm.locationOf(trapRef, at))
                return steps.cancel(Step.trap);
            if (!dm.creaturesNear(at, guardSlipkik, 1.5f, slipkik[]))
                break;
            dm.say(slipkik[0], saySlipkikTrap);
            dm.castSpell(slipkik[0], iceLock, slipkik[0]);
            dm.unitFlags(slipkik[0], UnitFlag.immuneToPlayer, true);
            dm.setFaction(slipkik[0], factionHostile);
            dm.despawnObject(trapRef);
            trapRef = EntityRef.init;
            steps.cancel(Step.trap);
            break;
        }
    }

    /// The ritual failed: its keeper, its objects, the circle and what it lit go.
    private void failRitual(ref InstanceContext dm)
    {
        ritual = Ritual.failed;
        dm.log("the Dreadsteed's ritual failed");
        if (keeperRef)
            dm.despawn(keeperRef);
        if (jeeveeRef)
            dm.despawn(jeeveeRef);
        foreach (ref o; ritualObjectRefs)
            if (o)
            {
                dm.despawnObject(o);
                o = EntityRef.init;
            }
        ritualActive[] = false;
        if (circleRef)
            dm.despawnObject(circleRef);
        foreach (o; scenery)
            dm.despawnObject(o);
        scenery.clear();
    }

    /// The waves are over: the demons go back through, and the circle is ready for the Dreadsteed.
    private void endRitual(ref InstanceContext dm)
    {
        if (ritual != Ritual.inProgress)
            return;
        ritual = Ritual.complete;
        foreach (demon; demons)
        {
            dm.castSpell(demon, teleportOut, demon);
            dm.say(demon, sayUnsummonDemon);
            dm.despawn(demon, 1000);
        }
        demons.clear();
        if (circleRef)
            dm.useObject(circleRef);
    }

    void on(ref InstanceContext dm, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case oldIronbark:
            ironbarkRef = e.creature;
            if (zevrimDead)
                dm.changeEntry(e.creature, ironbarkRedeemed);
            break;
        case prince:
            princeRef = e.creature;
            if (immoltharDead)
                dm.setFaction(e.creature, factionHostile);
            break;
        case immolthar: immoltharRef = e.creature; break;
        case arcaneAberration, manaRemnant: guardCandidates.add(e.creature); break;
        case highborneSummoner: summoners.add(e.creature); break;
        case kromcrush, chorush:
            (e.creature.entry == kromcrush ? kromcrushRef : chorushRef) = e.creature;
            if (gordokDead)
                dm.setFaction(e.creature, factionFriendly);
            break;
        case ritualKeeper: keeperRef = e.creature; break;
        case jeevee: jeeveeRef = e.creature; break;
        case xorothianImp, dreadGuard:
            // A wave's demon (the keeper's relay script brought it): to the pedestal.
            if (ritual == Ritual.inProgress)
            {
                demons.add(e.creature);
                Location at;
                if (dm.locationOf(e.creature, at))
                    dm.moveTo(e.creature, Location((at.x + ritualPedestal.x) / 2, (at.y + ritualPedestal.y) / 2, -32.0f));
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext dm, const ref CreatureEngaged e)
    {
        if (e.creature.entry == arcaneAberration || e.creature.entry == manaRemnant)
            sortPylonGuards(dm);
    }

    void on(ref InstanceContext dm, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case zevrim:
            zevrimDead = true;
            if (ironbarkRef)
            {
                dm.say(ironbarkRef, sayIronbarkRedeem);
                dm.changeEntry(ironbarkRef, ironbarkRedeemed);
            }
            break;
        case arcaneAberration, manaRemnant:
            foreach (i, ref guards; pylonGuards)
                if (!pylonDone[i] && guards.died(e.creature) && guards.allDead)
                    pylonOut(dm, i);
            break;
        case tendris:
            warpwoodDead = true;
            if (warpDoor)
                dm.door(warpDoor, true);
            break;
        case immolthar:
            immoltharDead = true;
            if (princeRef)
            {
                dm.say(princeRef, sayFreeImmolthar);
                dm.setFaction(princeRef, factionHostile);
            }
            break;
        case lordHelnurath:
            ritual = Ritual.done;
            break;
        case kingGordok:
            gordokDead = true;
            if (kromcrushRef && dm.alive(kromcrushRef))
                dm.setFaction(kromcrushRef, factionFriendly);
            if (chorushRef && dm.alive(chorushRef))
            {
                dm.say(chorushRef, sayChorushKingDead);
                dm.setFaction(chorushRef, factionFriendly);
                dm.summon(mizzle, mizzleSpawn);
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext dm, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.ritualStart:
            if (ritual != Ritual.inProgress)
                return;
            dm.respawnObject(ritualCircle, 900);
            dm.spawnObjects(dreadsteedPortal, 380);
            return;
        case Signals.ritualWave:
            if (ritual == Ritual.inProgress && e.value >= 1 && e.value <= 9)
                dm.spawnObjects(ritualSymbolEntries[(e.value - 1) / 3], 900, ritualSymbols[e.value - 1], 1.5f);
            return;
        case Signals.ritualDeactivate:
            // One of the three that burn goes out (a player may start it again).
            const first = dm.random(3);
            foreach (k; 0 .. 3)
            {
                const i = (first + k) % 3;
                if (ritualActive[i] && ritualObjectRefs[i])
                {
                    ritualActive[i] = false;
                    dm.door(ritualObjectRefs[i], false);
                    break;
                }
            }
            return;
        case Signals.ritualEnd:
            endRitual(dm);
            return;
        default:
            break;
        }
        if (e.id != Signals.alzzin)
            return;
        if ((e.value == 4 || e.value == 3) && !wallDown)
        {
            wallDown = true;
            if (wall)
                dm.door(wall, true);
        }
        if (e.value == 3 && !alzzinDead)
        {
            alzzinDead = true;
            if (vine)
                dm.door(vine, true);
            dm.spawnObjects(felvineShard, 3600);
        }
    }

    private @property bool allPylonsDone() const
    {
        foreach (done; pylonDone)
            if (!done)
                return false;
        return true;
    }

    /// The guards of each generator: those within twenty yards of it.
    private void sortPylonGuards(ref InstanceContext dm)
    {
        if (guardsSorted)
            return;
        guardsSorted = true;
        Location at;
        foreach (who; guardCandidates)
            if (dm.locationOf(who, at))
                foreach (i, place; generatorPlaces)
                    if ((at.x - place.x) ^^ 2 + (at.y - place.y) ^^ 2 < 20 * 20)
                    {
                        pylonGuards[i].add(who);
                        break;
                    }
    }

    private void pylonOut(ref InstanceContext dm, size_t i)
    {
        pylonDone[i] = true;
        if (generatorRefs[i])
            dm.door(generatorRefs[i], true);
        if (!allPylonsDone)
            return;
        dm.log("the five generators are out: the force field falls");
        if (field)
            dm.door(field, true);
        if (!immoltharRef || !dm.alive(immoltharRef))
            return;
        bool yelled;
        foreach (summoner; summoners)
        {
            if (!yelled)
                dm.say(summoner, sayKillImmolthar);
            yelled = true;
            dm.attack(summoner, immoltharRef);
        }
    }
}

/// The Dreadsteed's ritual's events (`event_spells_warlock_dreadsteed`: J'eevee released, the Dreadsteed
/// summoned): Dire Maul's script starts the ritual, or refuses the summoning before it is over
/// (`EventHappened`); the events' own script lets them through to it.
@scriptedEvent("event_spells_warlock_dreadsteed")
struct DreadsteedEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

/// The Bell of Dethmoora, the Wheel of the Black March and the Doomsday Candle (`go_dreadsteed_quest_objects`):
/// Dire Maul's script hears who starts them (`ObjectUsedHere`) and blesses them while they burn; their own
/// script lets the use (their start) follow.
@gameObject("go_dreadsteed_quest_objects")
struct DreadsteedQuestObject
{
    void on(ref GameObjectContext go, const ref ObjectUsed e) {}
}

/// The Fixed Trap (`go_fixed_trap`): only Guard Slip'kik springs it (Dire Maul's script watches for him);
/// players walking on it do not.
@gameObject("go_fixed_trap")
struct FixedTrap
{
    void on(ref GameObjectContext go, const ref ObjectUsed e) { go.consume(); }
}

/**
 * The keeper of the Dreadsteed's ritual (`npc_warlock_mount_ritual`): it brings J'eevee and walks her along
 * her path (her points' scripts set out the three objects); 48 seconds on the circle and the portals come,
 * then nine waves of demons (its relay scripts, 1450101 to 1450109), 45 seconds apart and the last short;
 * every 30 to 45 seconds one of the three objects goes out. Then the ritual is over and it goes.
 */
@creature("npc_warlock_mount_ritual")
struct WarlockMountRitual
{
    static immutable Location[5] jeeveePath = [
        Location(-37.9392f, 812.805f, -29.4525f), Location(-27.001f, 813.741f, -29.5358f), Location(-45.8222f, 821.969f, -29.5358f),
        Location(-43.6275f, 802.103f, -29.5358f), Location(-38.7195f, 812.015f, -29.5358f),
    ];
    static immutable uint[5] jeeveeScripts = [1_450_004, 1_450_005, 1_450_006, 1_450_007, 1_450_008];
    static immutable uint[5] jeeveeWaits = [8000, 7000, 7000, 7000, 30_000];
    enum uint firstWaveRelay = 1_450_100;

    enum Step : ubyte { jeeveeOn, phase, deactivate }
    Schedule!Step steps;
    EntityRef jeeveeRef;
    ubyte jeeveePoint, phase;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.combatMovement(false);
        jeeveeRef = me.summon(jeevee, ritualPlace);
        if (jeeveeRef)
        {
            me.movementScript(jeeveeRef, jeeveeScripts[0]);
            steps.after(Step.jeeveeOn, jeeveeWaits[0].msecs);
        }
        steps.after(Step.phase, 48.seconds);
        steps.after(Step.deactivate, 70.seconds);
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.summoned != jeeveeRef || e.point >= jeeveePath.length)
            return;
        me.movementScript(jeeveeRef, jeeveeScripts[e.point]);
        if (e.point + 1 < jeeveePath.length)
            steps.after(Step.jeeveeOn, jeeveeWaits[e.point].msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.jeeveeOn:
            ++jeeveePoint;
            if (jeeveePoint < jeeveePath.length)
                me.moveCreature(jeeveeRef, jeeveePath[jeeveePoint], jeeveePoint);
            break;
        case Step.phase:
            const k = ++phase;
            if (k == 1)
            {
                me.signalDungeon(DireMaul.Signals.ritualStart);
                steps.after(step, 1.seconds);
            }
            else if (k <= 10)
            {
                // Waves one to nine; the last a short one.
                me.relay(firstWaveRelay + (k - 1), me.self);
                me.signalDungeon(DireMaul.Signals.ritualWave, k - 1);
                steps.after(step, k < 10 ? 45.seconds : 17_500.msecs);
            }
            else
            {
                me.signalDungeon(DireMaul.Signals.ritualEnd);
                steps.clear();
                me.despawn();
            }
            break;
        case Step.deactivate:
            me.signalDungeon(DireMaul.Signals.ritualDeactivate);
            steps.after(step, (30_000 + me.random(15_001)).msecs);
            break;
        }
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.diremaul;
    auto dm = runInstance!self("instance_dire_maul");
    dm.raise(ObjectLoaded(objectRef(crumbleWall)));
    dm.raise(ObjectLoaded(objectRef(corruptVine)));
    dm.raise(Signal(creatureRef(11492), DireMaul.Signals.alzzin, 4));
    assert(dm.host.done("door 177220 open") && !dm.host.done("door 179502 open"));
    dm.raise(Signal(creatureRef(11492), DireMaul.Signals.alzzin, 3));
    assert(dm.host.done("door 179502 open") && dm.host.done("spawn objects 179559"));

    dm.raise(CreatureLoaded(creatureRef(oldIronbark)));
    dm.raise(CreatureDied(creatureRef(zevrim)));
    assert(dm.host.done("become 11491 14241"));

    // Two guards at each generator; all slain, the force field falls and the summoners turn on Immol'thar.
    foreach (g; generators)
        dm.raise(ObjectLoaded(objectRef(g)));
    dm.raise(ObjectLoaded(objectRef(forcefield)));
    dm.raise(CreatureLoaded(creatureRef(immolthar)));
    dm.raise(CreatureLoaded(creatureRef(highborneSummoner, 1)));
    foreach (i, place; generatorPlaces)
        foreach (k; 0 .. 2)
        {
            const guard = creatureRef(arcaneAberration, cast(uint)(100 + 2 * i + k));
            dm.host.places[guard.guid] = place;
            dm.raise(CreatureLoaded(guard));
        }
    dm.raise(CreatureEngaged(creatureRef(arcaneAberration, 100), playerRef));
    foreach (spawn; 100 .. 109)
        dm.raise(CreatureDied(creatureRef(arcaneAberration, spawn)));
    assert(dm.host.done("door 177259 open") && !dm.host.done("door 179503 open"));
    dm.raise(CreatureDied(creatureRef(arcaneAberration, 109)));
    assert(dm.host.done("door 179503 open") && dm.host.done("attack 11466"));

    dm.raise(CreatureLoaded(creatureRef(chorush)));
    dm.raise(CreatureDied(creatureRef(kingGordok)));
    assert(dm.host.done("summon 14353") && dm.host.done("faction 14324 35"));
}

/// The Dreadsteed's ritual: released, the keeper comes; J'eevee's objects burn and bless their users; the
/// waves end it and the Dreadsteed may come, not before; all three out and it fails.
unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.diremaul;
    auto dm = runInstance!self("instance_dire_maul");
    assert(dm.raise(EventHappened(DireMaul.summonDreadsteedEvent, playerRef, EntityRef.init)), "no Dreadsteed before the ritual");
    dm.raise(EventHappened(DireMaul.releaseJeeveeEvent, playerRef, EntityRef.init));
    assert(dm.host.done("summon 14501"));
    dm.raise(CreatureLoaded(creatureRef(ritualKeeper)));
    foreach (o; ritualObjects)
        dm.raise(ObjectLoaded(objectRef(o)));
    dm.run(6000);
    assert(dm.host.done("cast 14501 23117") && dm.host.done("cast 14501 23226"), "they bless their users");
    dm.raise(Signal(creatureRef(ritualKeeper), DireMaul.Signals.ritualWave, 4));
    assert(dm.host.done("spawn objects 179670"));
    dm.raise(CreatureLoaded(creatureRef(xorothianImp, 5)));
    dm.raise(Signal(creatureRef(ritualKeeper), DireMaul.Signals.ritualEnd));
    assert(dm.host.done("despawn 14482"));
    assert(!dm.raise(EventHappened(DireMaul.summonDreadsteedEvent, playerRef, EntityRef.init)),
        "the database script brings the Dreadsteed");

    // Another copy: the three go out, the ritual fails.
    auto dm2 = runInstance!self("instance_dire_maul");
    dm2.raise(EventHappened(DireMaul.releaseJeeveeEvent, playerRef, EntityRef.init));
    foreach (o; ritualObjects)
        dm2.raise(ObjectLoaded(objectRef(o)));
    foreach (_; 0 .. 3)
        dm2.raise(Signal(creatureRef(ritualKeeper), DireMaul.Signals.ritualDeactivate));
    dm2.run(1000);
    assert(dm2.host.done("despawn object 179674"));
    dm2.raise(EventHappened(DireMaul.releaseJeeveeEvent, playerRef, EntityRef.init));
    assert(dm2.host.times("summon 14501") == 2, "it may be tried again");
}
