/**
 * Scholomance (map 289): the gates that shut while their masters fight (Kirtonos the Herald's, and
 * the six rooms around the Great Ossuary: Malicia, Theolen, Polkelt, Ravenian, Alexei and Illucia
 * Barov), Darkmaster Gandling, who comes once the six are dead and shuts his own gate while he
 * fights, Ras Frostwhisper's door, the entrance hall filled again after Rattlegore's death, the
 * Dawn's Gambit thrown into the viewing room (the students turn, and Vectus and Marduk with them),
 * and the abilities of Gandling, Jandice Barov and the spectral tutors.
 */
module dmangos.scripts.scholomance;

import dmangos.script;

/// Creatures of Scholomance.
enum : uint
{
    necrofiend = 11551,
    risenAberration = 10485,
    diseasedGhoul = 10495,
    reanimatedCorpse = 10481,
    student = 10475,
    kirtonos = 10506,
    rattlegore = 11622,
    rasFrostwhisper = 10508,
    theolen = 11261,
    polkelt = 10901,
    ravenian = 10507,
    illucia = 10502,
    alexei = 10504,
    malicia = 10505,
    vectus = 10432,
    marduk = 10433,
    gandling = 1853,
}

/// Objects of Scholomance.
enum : uint
{
    gateKirtonos = 175570,
    viewingRoomDoor = 175167,
    gateRas = 177370,
    gateMalicia = 177375,
    gateTheolen = 177377,
    gatePolkelt = 177376,
    gateRavenian = 177372,
    gateBarov = 177373,
    gateIllucia = 177371,
    gateGandling = 177374,
}

/// Which way an encounter has gone.
enum Fight : ubyte { notStarted, inProgress, done, failed }

/// What Scholomance remembers (`instance.data`).
@instance("instance_scholomance")
struct Scholomance
{
    enum uint dawnGambitEvent = 5140;
    enum : int { sayGandlingSpawn = -1289000, yellVectusGambit = -1289001 }
    enum uint factionScourge = 233, studentTransform = 18115;

    /// The six masters of the rooms, each with its gate.
    static immutable uint[6] roomMasters = [malicia, theolen, polkelt, ravenian, alexei, illucia];
    static immutable uint[6] roomGates = [gateMalicia, gateTheolen, gatePolkelt, gateRavenian, gateBarov, gateIllucia];
    static immutable Location gandlingSpawn = Location(180.771f, -5.4286f, 75.5702f, 1.29154f);
    static immutable Location[17] entranceRoom = [
        Location(186.036f, 94.5f, 104.72f, 1.29154f), Location(179.117f, 95.5166f, 104.81f, 1.29154f),
        Location(180.612f, 100.176f, 104.80f, 1.29154f), Location(185.926f, 100.079f, 104.80f, 1.29154f),
        Location(178.999f, 75.2952f, 104.72f, 1.29154f), Location(185.558f, 77.276f, 104.72f, 1.29154f),
        Location(187.556f, 70.4334f, 104.72f, 1.29154f), Location(180.51f, 82.3917f, 104.72f, 1.29154f),
        Location(212.915f, 70.6005f, 104.80f, 1.29154f), Location(221.199f, 77.0037f, 104.72f, 1.29154f),
        Location(214.381f, 76.233f, 104.80f, 1.29154f), Location(218.64f, 71.5957f, 104.72f, 1.29154f),
        Location(221.249f, 94.9361f, 104.72f, 1.29154f), Location(214.406f, 101.903f, 104.72f, 1.29154f),
        Location(217.521f, 95.4237f, 104.72f, 1.29154f), Location(223.296f, 105.101f, 104.72f, 1.29154f),
        Location(209.233f, 73.2819f, 104.80f, 1.29154f),
    ];

    Fight kirtonosFight, rattlegoreFight, rasFight, gandlingFight;
    Fight[6] rooms;
    bool entranceRefilled, gambitThrown;
    @transient bool gandlingCalled; /// summoned since the copy loaded (a summon does not outlive a restart)
    @transient EntityRef[6] gates;
    @transient EntityRef kirtonosGate, rasGate, gandlingGate, viewingDoor, vectusRef, mardukRef;
    @transient Pack!40 students;

    enum Step : ubyte { gambit }
    Schedule!(Step, 2) steps;

    void on(ref InstanceContext scholo, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        foreach (i, gate; roomGates)
            if (entry == gate)
                gates[i] = e.object;
        switch (entry)
        {
        case gateKirtonos: kirtonosGate = e.object; break;
        case gateRas:
            rasGate = e.object;
            if (rasFight == Fight.done)
                scholo.door(e.object, true);
            break;
        case gateGandling: gandlingGate = e.object; break;
        case viewingRoomDoor:
            viewingDoor = e.object;
            if (rattlegoreFight == Fight.done)
                scholo.door(e.object, true);
            break;
        default: break;
        }
    }

    void on(ref InstanceContext scholo, const ref CreatureLoaded e)
    {
        switch (e.creature.entry)
        {
        case student: students.add(e.creature); break;
        case vectus: vectusRef = e.creature; break;
        case marduk: mardukRef = e.creature; break;
        default: break;
        }
        // Gandling comes when a player enters a copy whose six masters are dead (the copy reloaded).
        callGandlingIfCan(scholo, false);
    }

    void on(ref InstanceContext scholo, const ref CreatureEngaged e)
    {
        fight(scholo, e.creature.entry, Fight.inProgress);
    }

    void on(ref InstanceContext scholo, const ref CreatureEvaded e)
    {
        fight(scholo, e.creature.entry, Fight.failed);
    }

    void on(ref InstanceContext scholo, const ref CreatureDied e)
    {
        fight(scholo, e.creature.entry, Fight.done);
    }

    void on(ref InstanceContext scholo, const ref EventHappened e)
    {
        if (e.event != dawnGambitEvent || gambitThrown)
            return;
        scholo.consume();
        gambitThrown = true;
        steps.after(Step.gambit, 12.seconds);
    }

    /// The Dawn's Gambit: the viewing room's students become the Scourge they were.
    void on(ref InstanceContext scholo, Step step)
    {
        foreach (who; students)
        {
            scholo.setFaction(who, factionScourge);
            scholo.castSpell(who, studentTransform);
        }
        if (mardukRef)
            scholo.setFaction(mardukRef, factionScourge);
        if (vectusRef)
        {
            scholo.setFaction(vectusRef, factionScourge);
            scholo.say(vectusRef, yellVectusGambit);
        }
    }

    /// A master's fight began, was given up or was won: the gates follow.
    private void fight(ref InstanceContext scholo, uint entry, Fight how)
    {
        const open = how != Fight.inProgress;
        switch (entry)
        {
        case kirtonos:
            kirtonosFight = how;
            if (kirtonosGate)
                scholo.door(kirtonosGate, open);
            break;
        case rattlegore:
            rattlegoreFight = how;
            if (how == Fight.done)
            {
                if (viewingDoor)
                    scholo.door(viewingDoor, true);
                refillEntrance(scholo);
            }
            break;
        case rasFrostwhisper:
            rasFight = how;
            if (how == Fight.done && rasGate)
                scholo.door(rasGate, true);
            break;
        case gandling:
            gandlingFight = how;
            if (gandlingGate)
                scholo.door(gandlingGate, open);
            break;
        default:
            foreach (i, master; roomMasters)
                if (entry == master && rooms[i] != Fight.done)
                {
                    rooms[i] = how;
                    if (gates[i])
                        scholo.door(gates[i], open);
                    if (how == Fight.done)
                        callGandlingIfCan(scholo, true);
                }
            break;
        }
    }

    private void callGandlingIfCan(ref InstanceContext scholo, bool announce)
    {
        if (gandlingCalled || gandlingFight == Fight.done)
            return;
        foreach (room; rooms)
            if (room != Fight.done)
                return;
        gandlingCalled = true;
        if (const him = scholo.summon(gandling, gandlingSpawn))
            if (announce)
                scholo.say(him, sayGandlingSpawn);
    }

    /// After Rattlegore, the entrance hall fills again: four groups and a patrolling necrofiend.
    private void refillEntrance(ref InstanceContext scholo)
    {
        if (entranceRefilled)
            return;
        entranceRefilled = true;
        foreach (group; 0 .. 4)
        {
            uint[4] mobs = [risenAberration, risenAberration, diseasedGhoul, scholo.random(2) ? reanimatedCorpse : diseasedGhoul];
            foreach (j; 0 .. 4)
            {
                // Shuffled: one swap per place.
                const k = scholo.random(4);
                const t = mobs[j];
                mobs[j] = mobs[k];
                mobs[k] = t;
            }
            foreach (j; 0 .. 4)
                scholo.summon(mobs[j], entranceRoom[4 * group + j]);
        }
        scholo.summon(necrofiend, entranceRoom[16]);
    }
}

/// Darkmaster Gandling: arcane missiles, shadow shield, curse of the darkmaster; he sends players away through his shadow portal.
@creature("boss_darkmaster_gandling")
struct DarkmasterGandling
{
    enum : uint { arcaneMissiles = 15790, shadowShield = 12040, curse = 18702, shadowPortal = 17950 }

    enum Step : ubyte { missiles, shield, curse, portal }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.missiles, 4500.msecs);
        steps.after(Step.shield, 12.seconds);
        steps.after(Step.curse, 2.seconds);
        steps.after(Step.portal, 16.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.missiles:
            me.castSpell(arcaneMissiles);
            steps.after(Step.missiles, 8.seconds);
            break;
        case Step.shield:
            me.castSelf(shadowShield);
            steps.after(Step.shield, (14_000 + me.random(14_000)).msecs);
            break;
        case Step.curse:
            me.castSpell(curse);
            steps.after(Step.curse, (15_000 + me.random(12_000)).msecs);
            break;
        case Step.portal:
            if (me.healthPercent > 3)
                if (const target = me.randomTarget())
                    if (target.isPlayer)
                        me.castSpell(shadowPortal, target);
            steps.after(Step.portal, (20_000 + me.random(15_000)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// Jandice Barov: curse of blood, banish, and her illusions.
@creature("boss_jandice_barov")
struct JandiceBarov
{
    enum : uint { curseOfBlood = 16098, summonIllusions = 17773, spreadJandice = 17774, banish = 8994 }

    enum Step : ubyte { curse, illusions, banish }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.curse, 5.seconds);
        steps.after(Step.illusions, 15.seconds);
        steps.after(Step.banish, (9000 + me.random(4000)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.curse:
            me.castSelf(curseOfBlood);
            steps.after(Step.curse, (30_000 + me.random(5000)).msecs);
            break;
        case Step.illusions:
            if (me.castSelf(summonIllusions) == ActionResult.ok)
                me.castSelf(spreadJandice);
            steps.after(Step.illusions, 25.seconds);
            break;
        case Step.banish:
            if (const target = me.randomTarget())
                if (target != me.victim)
                    me.castSpell(banish, target);
            steps.after(Step.banish, (17_000 + me.random(4000)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// A Spectral Tutor: mana burn, silence, and its image projection (which heals it as it ends).
@creature("npc_spectral_tutor")
struct SpectralTutor
{
    enum : uint { imageProjection = 17651, projectionHeal = 17652, projectionSummon = 17653, manaBurn = 17630, silence = 12528 }

    enum Step : ubyte { manaBurn, silence, projection, projectionEnd }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.manaBurn, (4000 + me.random(15_000)).msecs);
        steps.after(Step.silence, me.random(3000).msecs);
        steps.after(Step.projection, (12_000 + me.random(1000)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.manaBurn:
            me.castSpell(manaBurn);
            steps.after(Step.manaBurn, (9000 + me.random(17_000)).msecs);
            break;
        case Step.silence:
            me.castSelf(silence);
            steps.after(Step.silence, (12_000 + me.random(14_000)).msecs);
            break;
        case Step.projection:
            if (me.castSelf(imageProjection) == ActionResult.ok)
            {
                me.castSelf(projectionSummon, true);
                steps.after(Step.projectionEnd, 1.seconds);
            }
            steps.after(Step.projection, (18_000 + me.random(7000)).msecs);
            break;
        case Step.projectionEnd:
            me.castSelf(projectionHeal);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

/// The Dawn's Gambit thrown (`event_dawn_gambit`): the dungeon's script turns the viewing room's students
/// (`EventHappened`); the event's own script lets it through to it.
@scriptedEvent("event_dawn_gambit")
struct DawnsGambitEvent
{
    void on(ref EventContext c, const ref EventStarted e) {}
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.scholomance;
    auto scholo = runInstance!self("instance_scholomance");
    foreach (gate; Scholomance.roomGates)
        scholo.raise(ObjectLoaded(objectRef(gate)));
    scholo.raise(ObjectLoaded(objectRef(gateKirtonos)));
    scholo.raise(CreatureEngaged(creatureRef(kirtonos), playerRef));
    assert(scholo.host.done("door 175570 closed"));
    scholo.raise(CreatureDied(creatureRef(kirtonos)));
    assert(scholo.host.done("door 175570 open"));
    scholo.raise(CreatureEngaged(creatureRef(malicia), playerRef));
    assert(scholo.host.done("door 177375 closed"));
    foreach (master; Scholomance.roomMasters[0 .. 5])
        scholo.raise(CreatureDied(creatureRef(master)));
    assert(!scholo.host.done("summon 1853"));
    scholo.raise(CreatureDied(creatureRef(illucia)));
    assert(scholo.host.done("summon 1853") && scholo.host.done("say 1853 -1289000"), "Gandling comes");
    scholo.raise(CreatureDied(creatureRef(rattlegore)));
    assert(scholo.host.times("summon 11551") == 1);
}
