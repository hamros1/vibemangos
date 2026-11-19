/**
 * Dire Maul (map 429): in the east, Old Ironbark redeemed when Zevrim Thornhoof falls, and Alzzin's
 * crumbling wall and corrupted vine (his creature script reports his fight); in the west, the five
 * crystal generators (each goes out when its guards are slain; with all five out the force field
 * around Immol'thar falls and the Highborne summoners turn on him; his death sets Prince
 * Tortheldrin against the players), and the door behind Tendris Warpwood; in the north, King
 * Gordok's death, which makes Kromcrush and Cho'Rush friendly and brings Mizzle the Crafty for the
 * tribute.
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
}

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
    enum Signals : uint { alzzin = 0 }
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
        default:
            break;
        }
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
