/**
 * The Temple of Atal'Hakkar (map 109): the Atal'ai statues (touched in their order, each lights a
 * green light; the sixth calls Atal'alarion, and a wrong one is ignored), the six troll protectors
 * whose deaths lower Jammal'an's barrier (and make him, Ogom and then the Shade of Eranikus open to
 * attack), the summoning of the Avatar of Hakkar (the Egg of Hakkar used at the altar calls his
 * Shade; while the four Eternal Flames are put out with the Hakkari blood, minions and blood keepers
 * pour out of the evil circles and suppressors come through the doors, each walking to the Shade to
 * suppress it: one left alive twenty seconds ends the ritual; the fourth flame brings the Avatar), and
 * Malfurion Stormrage's appearance before Eranikus for "Eranikus, Tyrant of the Dream".
 */
module dmangos.scripts.sunkentemple;

import dmangos.script;
import dmangos.script.state : appended;

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

    /// The waves, the next suppressor, and the time a suppressor's Suppression (12623) on the Shade gives the
    /// players to kill it before the ritual fails.
    enum Step : ubyte { wave, suppressor, suppression }
    Schedule!(Step, 4) steps;
    @appended bool statuesCheckpointed;
    @appended ubyte extinguishedFlames;

    /// What the Shade of Hakkar's EventAI tells the temple when a suppressor's Suppression hits it
    /// (`creature_ai_scripts` 844004: CMaNGOS's `SetData(TYPE_AVATAR, SPECIAL)`).
    enum uint typeAvatar = 4, avatarSpecial = 4;
    enum uint suppression = 12623;

    void on(ref InstanceContext st, const ref Restored e)
    {
        if (atalarionFight == Fight.inProgress && st.hasSavedCreature(atalarion))
            st.waitForPlayer();
        else if (atalarionFight != Fight.done && (!statuesCheckpointed || atalarionFight == Fight.inProgress))
        {
            atalarionFight = Fight.notStarted;
            statuesDone = 0;
        }
        if (avatar == Fight.inProgress
            && ((shade && st.hasSavedCreature(shade)) || st.hasSavedCreature(avatarOfHakkar)))
            st.waitForPlayer();
        else
        {
            if (avatar == Fight.inProgress)
                avatar = Fight.notStarted; // old saves lost the active ritual actors
            flamesOut = extinguishedFlames = 0;
            shade = EntityRef.init;
            steps.clear();
            if (statuesDone && statuesCheckpointed)
                st.waitForPlayer(); // restore the lights after the player loads the temple
        }
        malfurionCalled = false;
    }

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
        {
            doors[entry - hakkarDoor1] = e.object;
            if (avatar != Fight.notStarted)
                st.door(e.object, avatar != Fight.inProgress);
        }
        else if (entry >= eternalFlame1 && entry < eternalFlame1 + 4)
        {
            flames[entry - eternalFlame1] = e.object;
            if (avatar == Fight.inProgress && !(extinguishedFlames & (1 << (entry - eternalFlame1))))
                st.objectFlags(e.object, 0, ObjectFlag.noInteract);
            else if (avatar != Fight.notStarted)
                st.objectFlags(e.object, ObjectFlag.noInteract);
        }
        else if (entry == evilCircle)
        {
            circles.add(e.object);
            if (avatar == Fight.inProgress)
                st.checkpointObject(e.object);
        }
        else if (entry == atalaiLight || entry == atalaiLightBig || entry == idolOfHakkar)
            if (statuesCheckpointed)
                st.checkpointObject(e.object);
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
                statuesCheckpointed = true;
                Location at;
                if (e.target && st.locationOf(e.target, at))
                    st.spawnObjects(atalaiLight, 1800, at, 8);
                if (statuesDone == statueEvents.length)
                {
                    atalarionFight = Fight.inProgress;
                    if (const guardian = st.summon(atalarion, atalarionPlace))
                        st.checkpointCreature(guardian);
                    st.spawnObjects(idolOfHakkar, 1800);
                    st.spawnObjects(atalaiLightBig, 1800);
                }
                st.checkpoint();
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
            st.checkpoint();
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
            st.checkpoint();
            break;
        case bloodkeeper, hakkariMinion, suppressor:
            if (avatar == Fight.inProgress)
            {
                if (e.creature.entry == suppressor)
                    canBloodkeeper = true;
                st.checkpoint();
            }
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
        if (e.id == typeAvatar && e.value == avatarSpecial)
        {
            // A suppressor reached the Shade: twenty seconds to kill it, or the ritual fails. (Its spell hit is
            // told before its aura is on the Shade: the aura is looked for when the time is up.)
            if (avatar == Fight.inProgress && shade && !steps.pending(Step.suppression))
            {
                steps.after(Step.suppression, 20.seconds);
                st.checkpoint();
            }
        }
        else if (e.id == Signals.flameOut && avatar == Fight.inProgress)
        {
            const entry = e.from.entry;
            if (entry < eternalFlame1 || entry >= eternalFlame1 + 4)
                return;
            const bit = cast(ubyte)(1 << (entry - eternalFlame1));
            if (extinguishedFlames & bit)
                return;
            extinguishedFlames |= bit;
            st.objectFlags(e.from, ObjectFlag.noInteract);
            ++flamesOut;
            if (shade)
                st.say(shade, sayBrazier1 - (flamesOut - 1));
            if (flamesOut >= 4)
            {
                // The Avatar comes in the Shade's place.
                steps.clear();
                Location at = shadePlace, there;
                if (shade)
                {
                    if (st.locationOf(shade, there))
                        at = there;
                    st.despawn(shade);
                }
                if (const him = st.summon(avatarOfHakkar, at))
                {
                    st.checkpointCreature(him);
                    st.say(him, sayAvatarSpawn);
                }
                shade = EntityRef.init;
            }
            else
                steps.after(Step.suppressor, (15_000 + st.random(30_000)).msecs);
            st.checkpoint();
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
        case Step.suppression:
            if (shade && st.hasAura(shade, suppression))
                failAvatar(st);
            break;
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
                // Its door's path (`creature_movement_template` 8497, path 0 or 1): at its end it casts
                // Suppression on the Shade (`dbscripts_on_creature_movement` 849701).
                st.say(who, saySuppressor1 - cast(int) st.random(4));
                st.walkPath(who, door);
                st.checkpointCreature(who);
            }
            break;
        }
        st.checkpoint();
    }

    private void startAvatar(ref InstanceContext st)
    {
        avatar = Fight.inProgress;
        flamesOut = extinguishedFlames = 0;
        firstWave = true;
        foreach (flame; flames)
            if (flame)
                st.objectFlags(flame, 0, ObjectFlag.noInteract);
        st.spawnObjects(evilCircle, 30 * 60);
        shade = st.summon(shadeOfHakkar, shadePlace);
        if (shade)
            st.checkpointCreature(shade);
        openDoors(st, false);
        steps.after(Step.wave, 3.seconds);
        st.checkpoint();
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
        flamesOut = extinguishedFlames = 0;
        foreach (flame; flames)
            if (flame)
                st.objectFlags(flame, ObjectFlag.noInteract);
        openDoors(st, true);
        st.checkpoint();
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
            if (const who = st.summon(entry, at))
                st.checkpointCreature(who);
    }
}

/// An Eternal Flame: put out (with the Hakkari blood), it tells the temple.
/// Hex of Jammal'an: one it holds to the end is struck by its caster's two curses.
@spell("spell_hex_of_jammalan")
struct HexOfJammalan
{
    enum uint hexEnd1 = 12480, hexEnd2 = 12483;

    void on(ref SpellContext it, const ref AuraEnded e)
    {
        if (!e.expired || !e.caster)
            return;
        it.castSpell(e.caster, hexEnd1, e.target);
        it.castSpell(e.caster, hexEnd2, e.target);
    }
}

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

/// An Atal'ai statue used (`event_antalarion_statue_activation`): the dungeon's script checks the order and
/// brings Atal'alarion after the sixth (`EventHappened`); the event's own script lets it through to it.
@scriptedEvent("event_antalarion_statue_activation")
struct AtalaiStatueEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

/// The Soulflayer awakened (`event_avatar_of_hakkar`): the dungeon's script starts the Avatar of Hakkar's
/// ritual (`EventHappened`); the event's own script lets it through to it.
@scriptedEvent("event_avatar_of_hakkar")
struct AvatarOfHakkarEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
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
