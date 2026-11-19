/**
 * The Temple of Atal'Hakkar (map 109): the Atal'ai statues (touched in their order, each lights a
 * green light; the sixth calls Atal'alarion, and a wrong one is ignored), the six troll protectors
 * whose deaths lower Jammal'an's barrier (and make him, Ogom and then the Shade of Eranikus open to
 * attack), the summoning of the Avatar of Hakkar (the Egg of Hakkar used at the altar calls his
 * Shade; while the four Eternal Flames are put out with the Hakkari blood, minions and blood keepers
 * pour out of the evil circles and suppressors come through the doors; the fourth flame brings the
 * Avatar), and Malfurion Stormrage's appearance before Eranikus for "Eranikus, Tyrant of the Dream".
 */
module dmangos.scripts.sunkentemple;

import dmangos.script;

/// Creatures and objects of the temple.
enum : uint
{
    atalarion = 8580,
    jammalan = 5710,
    ogom = 5711,
    avatarOfHakkar = 8443,
    shadeOfEranikus = 5709,
    zolo = 5712,
    gasher = 5713,
    loro = 5714,
    hukku = 5715,
    zullor = 5716,
    mijan = 5717,
    shadeOfHakkar = 8440,
    bloodkeeper = 8438,
    hakkariMinion = 8437,
    suppressor = 8497,
    malfurion = 15362,

    idolOfHakkar = 148838,
    atalaiLight = 148883,
    atalaiLightBig = 148937,
    eternalFlame1 = 148418, // the four flames: 148418 to 148421
    evilCircle = 148998,
    hakkarDoor1 = 149432,
    hakkarDoor2 = 149433,
    jammalanBarrier = 149431,
}

/// The statues' events, in their order (event_antalarion_statue_activation), and the egg's.
static immutable uint[6] statueEvents = [3094, 3095, 3097, 3098, 3099, 3100];
enum uint avatarEvent = 8502;

/// An encounter's state.
enum Fight : ubyte { notStarted, inProgress, done, failed }

/// What the temple remembers (`instance.data`).
@instance("instance_sunken_temple")
struct SunkenTemple
{
    /// Signals: a flame put out (from the flame's script), Malfurion called (from the area trigger).
    enum Signals : uint { flameOut = 100, callMalfurion = 101 }
    enum : int
    {
        sayJammalanIntro = -1109005, sayBrazier1 = -1109006, sayAvatarSpawn = -1109010, saySuppressor1 = -1109011,
        sayAvatarDespawn = -1109015,
    }

    static immutable Location atalarionPlace = Location(-466.5130f, 95.19820f, -189.646f, 0.0349f);
    static immutable Location shadePlace = Location(-466.8673f, 272.31204f, -90.7441f, 3.5255f);
    static immutable Location malfurionPlace = Location(-660.5277f, -16.7117f, -90.8357f, 1.6055f);
    static immutable Location[2] doorPlaces = [Location(-420.629f, 276.682f, -90.827f), Location(-512.015f, 276.134f, -90.827f)];

    ubyte statuesDone;
    Fight atalarionFight, avatar;
    bool barrierDown, jammalanDead, malfurionCalled, firstWave, canBloodkeeper;
    ubyte flamesOut;
    Pack!8 protectors;
    Pack!8 circles;
    EntityRef shade;
    @transient EntityRef barrier, jammalanRef, ogomRef, eranikusRef;
    @transient EntityRef[2] doors;
    @transient EntityRef[4] flames;

    enum Step : ubyte { wave, suppressor }
    Schedule!(Step, 2) steps;

    void on(ref InstanceContext st, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        if (entry == jammalanBarrier)
        {
            barrier = e.object;
            if (barrierDown)
                st.door(e.object, true);
        }
        else if (entry == hakkarDoor1 || entry == hakkarDoor2)
            doors[entry - hakkarDoor1] = e.object;
        else if (entry >= eternalFlame1 && entry < eternalFlame1 + 4)
            flames[entry - eternalFlame1] = e.object;
        else if (entry == evilCircle)
            circles.add(e.object);
    }

    void on(ref InstanceContext st, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case zolo, gasher, loro, hukku, zullor, mijan:
            protectors.add(e.creature);
            break;
        case jammalan, ogom:
            (e.creature.entry == jammalan ? jammalanRef : ogomRef) = e.creature;
            if (barrierDown)
                st.unitFlags(e.creature, UnitFlag.immuneToPlayer, false);
            break;
        case shadeOfEranikus:
            eranikusRef = e.creature;
            if (jammalanDead)
                st.unitFlags(e.creature, UnitFlag.immuneToPlayer, false);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext st, const ref EventHappened e)
    {
        foreach (i, statue; statueEvents)
            if (e.event == statue)
            {
                st.consume();
                if (atalarionFight != Fight.notStarted || i != statuesDone)
                    return; // the wrong statue: nothing (its trap is the database's)
                ++statuesDone;
                Location at;
                if (e.target && st.locationOf(e.target, at))
                    st.spawnObjects(atalaiLight, 1800, at, 8);
                if (statuesDone == statueEvents.length)
                {
                    atalarionFight = Fight.inProgress;
                    st.summon(atalarion, atalarionPlace);
                    st.spawnObjects(idolOfHakkar, 1800);
                    st.spawnObjects(atalaiLightBig, 1800);
                }
                return;
            }
        if (e.event == avatarEvent)
        {
            st.consume();
            if (avatar == Fight.notStarted || avatar == Fight.failed)
                startAvatar(st);
        }
    }

    void on(ref InstanceContext st, const ref CreatureDied e)
    {
        circles.died(e.creature);
        switch (e.creature.entry)
        {
        case atalarion:
            atalarionFight = Fight.done;
            break;
        case jammalan:
            jammalanDead = true;
            if (eranikusRef)
                st.unitFlags(eranikusRef, UnitFlag.immuneToPlayer, false);
            break;
        case avatarOfHakkar:
            avatar = Fight.done;
            steps.clear();
            openDoors(st, true);
            break;
        case suppressor:
            canBloodkeeper = true;
            break;
        case zolo, gasher, loro, hukku, zullor, mijan:
            if (protectors.died(e.creature) && protectors.allDead && !barrierDown)
            {
                barrierDown = true;
                if (barrier)
                    st.door(barrier, true);
                if (jammalanRef)
                    st.say(jammalanRef, sayJammalanIntro);
                foreach (who; [jammalanRef, ogomRef])
                    if (who)
                        st.unitFlags(who, UnitFlag.immuneToPlayer, false);
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext st, const ref CreatureEvaded e)
    {
        switch (e.creature.entry)
        {
        case bloodkeeper, hakkariMinion, suppressor, avatarOfHakkar:
            if (avatar == Fight.inProgress)
                failAvatar(st);
            break;
        case jammalan, ogom, shadeOfEranikus:
            st.unitFlags(e.creature, UnitFlag.immuneToPlayer, false);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext st, const ref Signal e)
    {
        if (e.id == Signals.flameOut && avatar == Fight.inProgress)
        {
            if (e.from)
                st.objectFlags(e.from, ObjectFlag.noInteract);
            ++flamesOut;
            if (shade)
                st.say(shade, sayBrazier1 - (flamesOut - 1));
            if (flamesOut >= 4)
            {
                // The Avatar comes in the Shade's place.
                steps.clear();
                Location at = shadePlace;
                if (shade)
                {
                    st.locationOf(shade, at);
                    st.despawn(shade);
                }
                if (const him = st.summon(avatarOfHakkar, at))
                    st.say(him, sayAvatarSpawn);
                shade = EntityRef.init;
            }
            else
                steps.after(Step.suppressor, (15_000 + st.random(30_000)).msecs);
        }
        else if (e.id == Signals.callMalfurion && !malfurionCalled)
        {
            malfurionCalled = true;
            if (const him = st.summon(malfurion, malfurionPlace))
                st.signal(him, MalfurionStormrage.Signals.begin);
        }
    }

    void on(ref InstanceContext st, Step step)
    {
        if (avatar != Fight.inProgress || circles.empty)
            return;
        final switch (step)
        {
        case Step.wave:
            if (firstWave)
            {
                foreach (circle; circles)
                    summonAt(st, hakkariMinion, circle);
                summonAt(st, bloodkeeper, randomCircle(st));
                firstWave = canBloodkeeper = false;
                steps.after(Step.wave, 50.seconds);
            }
            else
            {
                const roll = st.random(100);
                uint count = roll < 75 ? 1 : roll < 95 ? 2 : 3;
                if (canBloodkeeper && st.random(100) < 30)
                {
                    summonAt(st, bloodkeeper, randomCircle(st));
                    canBloodkeeper = false;
                    --count;
                }
                foreach (_; 0 .. count)
                    summonAt(st, hakkariMinion, randomCircle(st));
                steps.after(Step.wave, (3000 + st.random(12_000)).msecs);
            }
            break;
        case Step.suppressor:
            const door = st.random(2);
            if (const who = st.summon(suppressor, doorPlaces[door]))
            {
                st.say(who, saySuppressor1 - cast(int) st.random(4));
                st.moveTo(who, shadePlace, 0, true);
            }
            break;
        }
    }

    private void startAvatar(ref InstanceContext st)
    {
        avatar = Fight.inProgress;
        flamesOut = 0;
        firstWave = true;
        foreach (flame; flames)
            if (flame)
                st.objectFlags(flame, 0, ObjectFlag.noInteract);
        st.spawnObjects(evilCircle, 30 * 60);
        shade = st.summon(shadeOfHakkar, shadePlace);
        openDoors(st, false);
        steps.after(Step.wave, 3.seconds);
    }

    private void failAvatar(ref InstanceContext st)
    {
        avatar = Fight.failed;
        steps.clear();
        if (shade)
        {
            st.say(shade, sayAvatarDespawn);
            st.despawn(shade);
            shade = EntityRef.init;
        }
        flamesOut = 0;
        foreach (flame; flames)
            if (flame)
                st.objectFlags(flame, ObjectFlag.noInteract);
        openDoors(st, true);
    }

    private void openDoors(ref InstanceContext st, bool open)
    {
        foreach (door; doors)
            if (door)
                st.door(door, open);
    }

    private EntityRef randomCircle(ref InstanceContext st)
    {
        uint pick = st.random(circles.alive);
        foreach (circle; circles)
            if (pick-- == 0)
                return circle;
        return EntityRef.init;
    }

    private void summonAt(ref InstanceContext st, uint entry, EntityRef circle)
    {
        Location at;
        if (circle && st.locationOf(circle, at))
            st.summon(entry, at);
    }
}

/// An Eternal Flame: put out (with the Hakkari blood), it tells the temple.
@gameObject("go_eternal_flame")
struct EternalFlame
{
    void on(ref GameObjectContext flame, const ref ObjectUsed e)
    {
        flame.signalDungeon(SunkenTemple.Signals.flameOut);
        flame.consume();
    }
}

/// Before the Shade of Eranikus: Malfurion appears to those who fight his tyranny (once a copy).
@areaTrigger("at_shade_of_eranikus")
struct AtShadeOfEranikus
{
    enum : uint { chargeOfDragonflights = 8555, tyrantOfDreams = 8733 }

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (at.questStatus(e.player, chargeOfDragonflights) == QuestProgress.rewarded
            && at.questStatus(e.player, tyrantOfDreams) != QuestProgress.rewarded
            && at.questStatus(e.player, tyrantOfDreams) != QuestProgress.complete)
            at.signalDungeon(SunkenTemple.Signals.callMalfurion);
    }
}

/// Malfurion Stormrage in the temple: he bows, speaks of Eranikus, and then gives his quest.
@creature("npc_malfurion_stormrage")
struct MalfurionStormrage
{
    enum : int { emoteWalls = -1109000, say1 = -1109001, say2 = -1109002, say3 = -1109003, say4 = -1109004 }
    enum : uint { spiritSpawnIn = 17321, questGiver = 2, emoteBow = 2, emoteTalk = 1 }

    enum Step : ubyte { speech }
    Schedule!Step steps;
    ubyte speech;
    bool begun;

    /// From the temple's script, which brought him: he begins (elsewhere he only gives his quests).
    enum Signals : uint { begin = 1 }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (begun || e.id != Signals.begin)
            return;
        begun = true;
        me.say(emoteWalls);
        me.castSelf(spiritSpawnIn, true);
        me.npcFlags(0);
        steps.after(Step.speech, 3.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        static immutable uint[6] waits = [2000, 12_000, 12_000, 11_000, 4000, 0];
        const now = speech++;
        switch (now)
        {
        case 0: me.emote(emoteBow); break;
        case 1: me.say(say1); me.emote(emoteTalk); break;
        case 2: me.say(say2); break;
        case 3: me.say(say3); break;
        case 4: me.say(say4); break;
        case 5: me.restoreNpcFlags(); me.emote(0); return;
        default: return;
        }
        steps.after(Step.speech, waits[now].msecs);
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.sunkentemple;
    auto st = runInstance!self("instance_sunken_temple");
    st.raise(EventHappened(statueEvents[1], playerRef, objectRef(1)));
    assert(!st.host.done("spawn objects 148883"), "the wrong statue");
    foreach (event; statueEvents)
        st.raise(EventHappened(event, playerRef, objectRef(1)));
    assert(st.host.times("spawn objects 148883") == 6 && st.host.done("summon 8580"));

    st.raise(ObjectLoaded(objectRef(jammalanBarrier)));
    st.raise(CreatureLoaded(creatureRef(jammalan)));
    foreach (entry; [zolo, gasher, loro, hukku, zullor, mijan])
        st.raise(CreatureLoaded(creatureRef(entry)));
    foreach (entry; [zolo, gasher, loro, hukku, zullor])
        st.raise(CreatureDied(creatureRef(entry)));
    assert(!st.host.done("door 149431 open"));
    st.raise(CreatureDied(creatureRef(mijan)));
    assert(st.host.done("door 149431 open") && st.host.done("say 5710 -1109005") && st.host.done("flags 5710 +0 -100"));

    // The Avatar: the egg, the waves, four flames.
    foreach (spawn; 1 .. 9)
        st.raise(ObjectLoaded(objectRef(evilCircle, spawn)));
    st.raise(ObjectLoaded(objectRef(hakkarDoor1)));
    st.raise(EventHappened(avatarEvent, playerRef, EntityRef.init));
    assert(st.host.done("summon 8440") && st.host.done("door 149432 closed"));
    st.run(3000);
    assert(st.host.times("summon 8437") == 8 && st.host.times("summon 8438") == 1);
    foreach (i; 0 .. 4)
        st.raise(Signal(objectRef(eternalFlame1 + i), SunkenTemple.Signals.flameOut));
    assert(st.host.done("despawn 8440") && st.host.done("summon 8443") && st.host.done("say 8443 -1109010"));
    st.raise(CreatureDied(creatureRef(avatarOfHakkar, 1000)));
    assert(st.host.done("door 149432 open"));
}
