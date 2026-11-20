/**
 * Gnomeregan (map 90): Blastmaster Emi Shortfuse's stand at the cave-ins (she is escorted to the two
 * tunnels the troggs dig, holds them while the players fight off their waves, and blows both shut,
 * Grubbis coming out of the second; his death brings the red rockets), Kernobee, who follows his
 * rescuer out of the city ("A Fine Mess", quest 2904), and Mekgineer Thermaplugg, whose gnome faces
 * spit walking bombs at the players until their buttons are pressed, the Final Chamber's door locked
 * behind them while he fights.
 */
module dmangos.scripts.gnomeregan;

import core.time : Duration;

import dmangos.script;

/// Creatures and objects of the city.
enum : uint
{
    thermaplugg = 7800,
    walkingBomb = 7915,
    blastmaster = 7998,
    grubbis = 7361,
    chomper = 6215,
    caverndeepBurrower = 6206,
    caverndeepAmbusher = 6207,
    kernobee = 7850,

    redRocket = 103820,
    caveInNorth = 146085,
    caveInSouth = 146086,
    explosiveCharge = 144065,
    finalChamber = 142207,
    gnomeFace1 = 142211,
    gnomeFace2 = 142210,
    gnomeFace3 = 142209,
    gnomeFace4 = 142208,
    gnomeFace5 = 142213,
    gnomeFace6 = 142212,
    button1 = 142214, // its face is the face of the same number; buttons 1 to 6 are 142214 to 142219
}

/// Where the cave-ins are (their spawns).
enum Location southCaveIn = Location(-541.607f, -105.434f, -151.829f), northCaveIn = Location(-505.096f, -93.973f, -147.814f);

/// What the city remembers: Grubbis's and Thermaplugg's fights (`instance.data`).
@instance("instance_gnomeregan")
struct Gnomeregan
{
    /// Signals: Emi's event (`value`: one of `Emi.Event`), Thermaplugg's fight, a face button pressed
    /// (`value`: the face, 0 to 5), Thermaplugg's spell arming a face at random.
    enum Signals : uint { emi = 100, thermaplugg = 101, button = 102, armFace = 103 }
    enum Fight : int { notStarted, inProgress, done, failed }

    Fight grubbisFight, thermapluggFight;
    /// Thermaplugg's fight as it goes: not saved (a restart ends it: no face spits at nobody, the chamber opens).
    @transient bool[6] faceArmed;
    @transient Pack!16 bombs;      /// the walking bombs out
    @transient EntityRef door, emi;
    @transient EntityRef[6] faces;
    @transient EntityRef[2] caveIns; /// south, north

    enum Step : ubyte { face0, face1, face2, face3, face4, face5 }
    @transient Schedule!(Step, 6) bombTimers;

    private static immutable uint[6] faceEntries = [gnomeFace1, gnomeFace2, gnomeFace3, gnomeFace4, gnomeFace5, gnomeFace6];
    /// Where the faces are (their spawns), and Thermaplugg.
    private static immutable Location[6] facePlaces = [
        Location(-561.236f, 709.881f, -327.485f), Location(-518.904f, 718.472f, -327.505f),
        Location(-485.723f, 690.871f, -327.5f), Location(-486.665f, 647.652f, -327.485f),
        Location(-521.022f, 621.549f, -327.485f), Location(-562.961f, 632.162f, -327.485f),
    ];
    enum Location thermapluggPlace = Location(-531.324f, 670.159f, -325.185f);

    void on(ref InstanceContext city, const ref ObjectLoaded e)
    {
        const entry = e.object.entry;
        if (entry == finalChamber)
        {
            door = e.object;
            if (thermapluggFight == Fight.inProgress && !bombTimers.busy)
                thermapluggFight = Fight.failed; // a fight cut by a restart: over
            if (thermapluggFight != Fight.inProgress)
            {
                city.objectFlags(e.object, 0, ObjectFlag.locked);
                city.door(e.object, true);
            }
        }
        else if (entry == caveInSouth || entry == caveInNorth)
            caveIns[entry == caveInSouth ? 0 : 1] = e.object;
        foreach (i, face; faceEntries)
            if (entry == face)
                faces[i] = e.object;
    }

    void on(ref InstanceContext city, const ref CreatureLoaded e)
    {
        if (e.creature.entry == blastmaster)
        {
            emi = e.creature;
            if (grubbisFight == Fight.done)
                city.signal(e.creature, Emi.Signals.grubbisDone);
        }
    }

    void on(ref InstanceContext city, const ref CreatureDied e)
    {
        bombs.died(e.creature);
        if (e.creature.entry == grubbis && grubbisFight == Fight.inProgress)
        {
            grubbisFight = Fight.done;
            city.spawnObjects(redRocket, 3600, Location(-511, -139, -152), 10);
            if (emi)
                city.signal(emi, Emi.Signals.grubbisDead);
        }
        else if (e.creature.entry == blastmaster && grubbisFight == Fight.inProgress)
            grubbisFight = Fight.failed;
        else if (e.creature.entry == thermaplugg)
            thermapluggOver(city, Fight.done);
    }

    void on(ref InstanceContext city, const ref Signal e)
    {
        switch (e.id)
        {
        case Signals.emi:
            if (e.value >= Emi.Event.min && e.value <= Emi.Event.max)
                emiEvent(city, cast(Emi.Event) e.value);
            break;
        case Signals.thermaplugg:
            if (e.value < Fight.min || e.value > Fight.max)
                break;
            if (e.value == Fight.inProgress)
            {
                thermapluggFight = Fight.inProgress;
                if (door)
                {
                    city.door(door, false);
                    city.objectFlags(door, ObjectFlag.locked);
                }
                arm(city, 2);
            }
            else
                thermapluggOver(city, cast(Fight) e.value);
            break;
        case Signals.button:
            if (e.value >= 0 && e.value < 6)
                disarm(city, e.value);
            break;
        case Signals.armFace:
            arm(city, city.random(6));
            break;
        default:
            break;
        }
    }

    /// A face spits a walking bomb, which rolls towards Thermaplugg's place (and the players there).
    void on(ref InstanceContext city, Step step)
    {
        const i = cast(size_t) step;
        if (!faceArmed[i] || thermapluggFight != Fight.inProgress)
            return;
        const at = Location(0.35f * thermapluggPlace.x + 0.65f * facePlaces[i].x,
            0.35f * thermapluggPlace.y + 0.65f * facePlaces[i].y, -316.2625f);
        if (const bomb = city.summon(walkingBomb, at))
        {
            bombs.add(bomb);
            city.moveTo(bomb, thermapluggPlace, 1, true);
        }
        bombTimers.after(step, (10_000 + city.random(15_000)).msecs);
    }

    private void arm(ref InstanceContext city, uint face)
    {
        if (face >= 6 || faceArmed[face])
            return;
        faceArmed[face] = true;
        if (faces[face])
            city.door(faces[face], true);
        bombTimers.after(cast(Step) face, 3.seconds);
    }

    private void disarm(ref InstanceContext city, int face)
    {
        if (!faceArmed[face])
            return;
        faceArmed[face] = false;
        if (faces[face])
            city.door(faces[face], false);
        bombTimers.cancel(cast(Step) face);
    }

    private void thermapluggOver(ref InstanceContext city, Fight how)
    {
        thermapluggFight = how;
        if (door)
        {
            city.objectFlags(door, 0, ObjectFlag.locked);
            city.door(door, true);
        }
        foreach (i; 0 .. 6)
            disarm(city, i);
        if (how != Fight.done)
            foreach (bomb; bombs)
                city.despawn(bomb);
        bombs.clear();
    }

    private void emiEvent(ref InstanceContext city, Emi.Event what)
    {
        final switch (what)
        {
        case Emi.Event.started:
            grubbisFight = Fight.inProgress;
            break;
        case Emi.Event.openSouth, Emi.Event.closeSouth:
            if (caveIns[0])
                city.door(caveIns[0], what == Emi.Event.openSouth);
            break;
        case Emi.Event.openNorth, Emi.Event.closeNorth:
            if (caveIns[1])
                city.door(caveIns[1], what == Emi.Event.openNorth);
            break;
        case Emi.Event.chargeSouth:
            city.spawnObjects(explosiveCharge, 30, southCaveIn, 12);
            break;
        case Emi.Event.chargeNorth:
            city.spawnObjects(explosiveCharge, 40, northCaveIn, 12);
            break;
        case Emi.Event.grubbis:
            // Grubbis and Chomper come out of the northern tunnel, for Emi.
            if (const him = city.summon(grubbis, Location(-476.3761f, -108.1901f, -145.7763f, 1.919862f), 0, emi))
                city.say(him, Emi.sayGrubbis);
            city.summon(chomper, Location(-473.1326f, -103.0901f, -146.1155f, 2.042035f), 0, emi);
            break;
        }
    }
}

/// Blastmaster Emi Shortfuse: see the module documentation.
@creature("npc_blastmaster_emi_shortfuse")
struct Emi
{
    enum Signals : uint { grubbisDone = 1, grubbisDead = 2 }
    /// What she tells the city's script.
    enum Event : int { started, openSouth, closeSouth, openNorth, closeNorth, chargeSouth, chargeNorth, grubbis }
    enum uint begin = 1;
    enum : int
    {
        sayStart = -1090000, sayIntro1 = -1090001, sayIntro2 = -1090002, sayIntro3 = -1090003, sayIntro4 = -1090004,
        sayLook1 = -1090005, sayHear1 = -1090006, sayAggro1 = -1090007, sayCharge1 = -1090008, sayCharge2 = -1090009,
        sayBlow1in10 = -1090010, sayBlow1in5 = -1090011, sayBlow1 = -1090012, sayFinish1 = -1090013,
        sayLook2 = -1090014, sayHear2 = -1090015, sayCharge3 = -1090016, sayCharge4 = -1090017,
        sayBlow2in10 = -1090018, sayBlow2in5 = -1090019, sayBlowSoon = -1090020, sayBlow2 = -1090021,
        sayFinish2 = -1090022, sayGrubbis = -1090023, sayAggro2 = -1090028,
    }
    enum : uint { explosionNorth = 12158, explosionSouth = 12159, fireworksRed = 11542 }
    enum : uint { emoteUseStanding = 69, emoteNone = 0, emoteCheer = 4, emotePoint = 25 }

    /// The troggs, by the pack (1 to 6) they come in (Grubbis, the seventh, the dungeon's script brings).
    static struct Trogg { ubyte pack; uint entry; Location at; }
    static immutable Trogg[31] troggs = [
        Trogg(1, caverndeepAmbusher, Location(-566.8114f, -111.7036f, -151.1891f, 5.986479f)),
        Trogg(1, caverndeepAmbusher, Location(-568.5875f, -113.7559f, -151.1869f, 0.06981317f)),
        Trogg(1, caverndeepAmbusher, Location(-570.2333f, -116.8126f, -151.2272f, 0.296706f)),
        Trogg(1, caverndeepAmbusher, Location(-550.6331f, -108.7592f, -153.965f, 0.8901179f)),
        Trogg(1, caverndeepAmbusher, Location(-558.9717f, -115.0669f, -151.8799f, 0.5235988f)),
        Trogg(1, caverndeepAmbusher, Location(-556.6719f, -112.0526f, -152.8255f, 0.4886922f)),
        Trogg(1, caverndeepAmbusher, Location(-552.6419f, -113.4385f, -153.0727f, 0.8028514f)),
        Trogg(1, caverndeepAmbusher, Location(-549.1248f, -112.1469f, -153.7987f, 0.7504916f)),
        Trogg(1, caverndeepAmbusher, Location(-546.7435f, -112.3051f, -154.2225f, 0.9250245f)),
        Trogg(2, caverndeepAmbusher, Location(-571.4071f, -108.7721f, -150.6547f, 5.480334f)),
        Trogg(2, caverndeepAmbusher, Location(-573.797f, -106.5265f, -150.4106f, 5.550147f)),
        Trogg(2, caverndeepAmbusher, Location(-576.3784f, -108.0483f, -150.4227f, 5.585053f)),
        Trogg(2, caverndeepAmbusher, Location(-576.697f, -111.7413f, -150.6484f, 5.759586f)),
        Trogg(3, caverndeepAmbusher, Location(-571.3161f, -114.4412f, -151.0931f, 6.021386f)),
        Trogg(3, caverndeepAmbusher, Location(-570.3127f, -111.7964f, -151.04f, 2.042035f)),
        Trogg(4, caverndeepAmbusher, Location(-474.5954f, -104.074f, -146.0483f, 2.338741f)),
        Trogg(4, caverndeepAmbusher, Location(-477.9396f, -108.6563f, -145.7394f, 1.553343f)),
        Trogg(4, caverndeepAmbusher, Location(-475.6625f, -97.12168f, -146.5959f, 1.291544f)),
        Trogg(4, caverndeepAmbusher, Location(-480.5233f, -88.40702f, -146.3772f, 3.001966f)),
        Trogg(5, caverndeepAmbusher, Location(-474.2943f, -105.2212f, -145.9747f, 2.251475f)),
        Trogg(5, caverndeepAmbusher, Location(-481.1831f, -101.4225f, -146.377f, 2.146755f)),
        Trogg(5, caverndeepBurrower, Location(-475.0871f, -100.016f, -146.4382f, 2.303835f)),
        Trogg(5, caverndeepAmbusher, Location(-478.8562f, -106.9321f, -145.8533f, 1.658063f)),
        Trogg(6, caverndeepAmbusher, Location(-473.8762f, -107.4022f, -145.838f, 2.024582f)),
        Trogg(6, caverndeepAmbusher, Location(-490.5134f, -92.72843f, -148.0954f, 3.054326f)),
        Trogg(6, caverndeepAmbusher, Location(-491.401f, -88.25341f, -148.0358f, 3.560472f)),
        Trogg(6, caverndeepAmbusher, Location(-479.1431f, -106.227f, -145.9097f, 1.727876f)),
        Trogg(6, caverndeepAmbusher, Location(-475.3185f, -101.4804f, -146.2717f, 2.234021f)),
        Trogg(6, caverndeepAmbusher, Location(-485.1559f, -89.57419f, -146.9299f, 3.071779f)),
        Trogg(6, caverndeepAmbusher, Location(-482.2516f, -96.80614f, -146.6596f, 2.303835f)),
        Trogg(6, caverndeepAmbusher, Location(-477.9874f, -92.82047f, -146.6944f, 3.124139f)),
    ];

    enum Step : ubyte { phase, openSouth, sayCharge1 }
    Schedule!Step steps;
    Escort escort;
    EntityRef player;
    ubyte phase;
    bool started, grubbisDone, spoke;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.grubbisDone)
        {
            grubbisDone = true;
            me.npcFlags(0);
        }
        else if (e.id == Signals.grubbisDead)
            next(1.seconds);
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (started || grubbisDone)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "I am ready to begin.", begin);
        me.sendGossip(e.player, 0, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != begin || started || grubbisDone)
            return;
        me.closeGossip(e.player);
        started = true;
        player = e.player;
        phase = 1;
        me.signalDungeon(Gnomeregan.Signals.emi, Event.started);
        next(1.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (spoke || !started)
            return;
        spoke = true;
        if (me.random(3) == 0)
            me.say(me.random(2) ? sayAggro1 : sayAggro2, e.enemy);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        // The database's points count from 1.
        switch (escort.reached(me, e) + 1)
        {
        case 4: next(1.seconds); break;
        case 9:
            next(2.seconds);
            steps.after(Step.openSouth, 27.seconds); // as she sets off for point 10
            break;
        case 11:
            me.emote(emoteUseStanding);
            next(15.seconds);
            steps.after(Step.sayCharge1, 30.seconds);
            break;
        case 13:
            me.emote(emoteUseStanding);
            next(10.seconds);
            break;
        case 15:
            escort.paused = true;
            me.say(sayBlow1in10);
            next(5.seconds);
            break;
        case 16:
            me.emote(emoteUseStanding);
            next(15.seconds);
            break;
        case 17:
            me.emote(emoteUseStanding);
            next(10.seconds);
            break;
        case 19:
            escort.paused = true; // and she stays
            next(2.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.openSouth:
            me.signalDungeon(Gnomeregan.Signals.emi, Event.openSouth);
            break;
        case Step.sayCharge1:
            me.say(sayCharge1);
            break;
        case Step.phase:
            runPhase(me);
            break;
        }
    }

    /// The next phase after `delay` (phases waiting for a point have none until she reaches it).
    private void next(Duration delay)
    {
        steps.after(Step.phase, delay);
    }

    private void runPhase(ref CreatureContext me)
    {
        const current = phase++;
        switch (current)
        {
        case 1:
            me.say(sayStart);
            me.setFaction(113); // FACTION_ESCORT_N_NEUTRAL_PASSIVE
            me.npcFlags(0);
            next(5.seconds);
            break;
        case 2:
            me.say(sayIntro1);
            next(3500.msecs);
            break;
        case 3:
            escort.start(me, player, 0);
            break;
        case 4: me.say(sayIntro2); break;
        case 5: me.say(sayIntro3); next(6.seconds); break;
        case 6: me.say(sayIntro4); next(9.seconds); break;
        case 7: next(2.seconds); break;
        case 8: me.say(sayLook1); next(5.seconds); break;
        case 9: me.say(sayHear1); next(2.seconds); break;
        case 10: pack(me, 1); break;
        case 11:
            pack(me, 2);
            me.signalDungeon(Gnomeregan.Signals.emi, Event.chargeSouth);
            me.emote(emoteNone);
            next(1.msecs);
            break;
        case 12: break;
        case 13:
            pack(me, 3);
            me.emote(emoteNone);
            next(11.seconds);
            break;
        case 14: next(1.msecs); break;
        case 15: me.say(sayCharge2); break;
        case 16: me.say(sayBlow1in5); next(5.seconds); break;
        case 17: me.say(sayBlow1); next(1.seconds); break;
        case 18: me.castSelf(explosionSouth); next(500.msecs); break;
        case 19:
            me.signalDungeon(Gnomeregan.Signals.emi, Event.closeSouth);
            next(5.seconds);
            break;
        case 20: me.emote(emoteCheer); next(6.seconds); break;
        case 21: me.say(sayFinish1); next(6.seconds); break;
        case 22: me.say(sayLook2); next(3.seconds); break;
        case 23: next(3.seconds); break;
        case 24: me.say(sayHear2); next(8.seconds); break;
        case 25:
            escort.paused = false; // on to point 16: the northern cave-in opens as she goes
            me.say(sayCharge3);
            me.signalDungeon(Gnomeregan.Signals.emi, Event.openNorth);
            pack(me, 4);
            break;
        case 26:
            pack(me, 5);
            me.signalDungeon(Gnomeregan.Signals.emi, Event.chargeNorth);
            me.emote(emoteNone);
            next(1.msecs);
            break;
        case 27: break;
        case 28:
            pack(me, 6);
            me.emote(emoteNone);
            next(10.seconds);
            break;
        case 29: next(1.msecs); break;
        case 30: me.say(sayCharge4); break;
        case 31: me.say(sayBlow2in10); next(5.seconds); break;
        case 32: me.say(sayBlow2in5); next(1.seconds); break;
        case 33: me.signalDungeon(Gnomeregan.Signals.emi, Event.grubbis); break; // his death goes on
        case 34: me.emote(emoteCheer); next(5.seconds); break;
        case 35: me.say(sayBlowSoon); next(5.seconds); break;
        case 36: me.say(sayBlow2); next(2.seconds); break;
        case 37: me.emote(emotePoint); next(1.seconds); break;
        case 38: me.castSelf(explosionNorth); next(500.msecs); break;
        case 39:
            me.signalDungeon(Gnomeregan.Signals.emi, Event.closeNorth);
            next(8.seconds);
            break;
        case 40:
            me.castSelf(fireworksRed);
            me.say(sayFinish2);
            break;
        default:
            break;
        }
    }

    /// The troggs of pack `index` come out of the tunnel, for her.
    private void pack(ref CreatureContext me, ubyte index)
    {
        foreach (ref t; troggs)
            if (t.pack == index)
                me.summon(t.entry, t.at, 0, me.self);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.active = false;
        if (started)
        {
            // The tunnels she opened close again.
            if (phase > 9 && phase <= 19)
                me.signalDungeon(Gnomeregan.Signals.emi, Event.closeSouth);
            if (phase > 25 && phase <= 39)
                me.signalDungeon(Gnomeregan.Signals.emi, Event.closeNorth);
        }
    }
}

/**
 * Kernobee: freed for "A Fine Mess", he follows the player to the clean zone's door; there the
 * quest's event happens, and he walks out and goes.
 */
@creature("npc_kernobee")
struct Kernobee
{
    enum uint quest = 2904;
    enum Location endPlace = Location(-330.92f, -3.03f, -152.85f), exitPlace = Location(-297.32f, -7.32f, -152.85f);

    enum Step : ubyte { check }
    Schedule!Step steps;
    EntityRef leader;
    bool done;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != quest || leader)
            return;
        leader = e.player;
        me.standState(StandState.stand);
        me.npcFlags(0);
        me.follow(e.player);
        steps.every(Step.check, 10.seconds, 500.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (done || me.inCombat)
            return;
        if (!me.alive(leader) || me.distanceTo(leader) > 100)
        {
            me.failQuest(leader, quest);
            steps.clear();
            me.despawn(1000);
            return;
        }
        const at = me.location;
        if ((at.x - endPlace.x) ^^ 2 + (at.y - endPlace.y) ^^ 2 + (at.z - endPlace.z) ^^ 2 < 10 * 10)
        {
            done = true;
            steps.clear();
            me.questEvent(leader, quest);
            me.moveTo(exitPlace, 1);
            me.despawn(2000);
        }
    }
}

/**
 * Mekgineer Thermaplugg: knocks his foe away (in his second half, everyone around), and arms the
 * gnome faces around his chamber, which then spit walking bombs (the dungeon's script) until their
 * buttons are pressed.
 */
@creature("boss_thermaplugg")
struct Thermaplugg
{
    enum : int { sayAggro = -1090024, sayPhase = -1090025, sayBomb = -1090026, saySlay = -1090027 }
    enum : uint { activateBombA = 11511, activateBombB = 11795, knockAway = 10101, knockAwayAoe = 11130 }

    enum Step : ubyte { knockAway, activateBomb }
    Schedule!Step steps;
    bool phaseTwo;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.signalDungeon(Gnomeregan.Signals.thermaplugg, Gnomeregan.Fight.inProgress);
        steps.after(Step.knockAway, (12_000 + me.random(8000)).msecs);
        steps.after(Step.activateBomb, (10_000 + me.random(5000)).msecs);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!phaseTwo && e.after < 50)
        {
            phaseTwo = true;
            me.say(sayPhase);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.knockAway:
            if (phaseTwo)
                me.castSelf(knockAwayAoe);
            else
                me.castSpell(knockAway);
            steps.after(Step.knockAway, phaseTwo ? 12.seconds : (17_000 + me.random(3000)).msecs);
            break;
        case Step.activateBomb:
            me.castSelf(phaseTwo ? activateBombB : activateBombA);
            me.signalDungeon(Gnomeregan.Signals.armFace);
            if (me.random(6) == 0)
                me.say(sayBomb);
            steps.after(Step.activateBomb, ((phaseTwo ? 6 + me.random(7) : 12 + me.random(6)) * 1000).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        me.say(saySlay);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        phaseTwo = false;
        me.signalDungeon(Gnomeregan.Signals.thermaplugg, Gnomeregan.Fight.failed);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// A button by a gnome face: pressed, its face stops spitting bombs.
@gameObject("go_gnomeface_button")
struct GnomefaceButton
{
    void on(ref GameObjectContext button, const ref ObjectUsed e)
    {
        const face = cast(int) button.self.entry - cast(int) button1;
        if (face >= 0 && face < 6)
            button.signalDungeon(Gnomeregan.Signals.button, face);
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.gnomeregan;
    auto city = runInstance!self("instance_gnomeregan");
    foreach (entry; [finalChamber, gnomeFace1, gnomeFace2, gnomeFace3, gnomeFace4, gnomeFace5, gnomeFace6])
        city.raise(ObjectLoaded(objectRef(entry)));
    city.raise(Signal(creatureRef(thermaplugg), Gnomeregan.Signals.thermaplugg, Gnomeregan.Fight.inProgress));
    assert(city.host.done("door 142207 closed") && city.host.done("object flags 142207 +2 -0"));
    assert(city.host.done("door 142209 open"), "the third face armed at once");
    city.run(3000);
    assert(city.host.times("summon 7915") == 1 && city.host.done("move 7915 1"));
    city.run(10_000);
    assert(city.host.times("summon 7915") == 2, "and again");
    city.raise(Signal(objectRef(button1 + 2), Gnomeregan.Signals.button, 2));
    assert(city.host.done("door 142209 closed"));
    city.run(30_000);
    assert(city.host.times("summon 7915") == 2, "pressed: no more bombs");
    city.raise(CreatureDied(creatureRef(thermaplugg)));
    assert(city.host.done("door 142207 open") && city.state!Gnomeregan.thermapluggFight == Gnomeregan.Fight.done);

    // Emi: her gossip starts the stand; the troggs come in packs as she goes.
    auto emi = runCreature!self("npc_blastmaster_emi_shortfuse", blastmaster);
    foreach (i; 0 .. 19)
        emi.host.path ~= Waypoint(Location(i, 0, 0));
    emi.raise(GossipHello(playerRef));
    assert(emi.host.done("gossip 1"));
    emi.raise(GossipSelect(playerRef, 0, 0, Emi.begin));
    assert(emi.host.done("dungeon 100 0"));
    emi.run(10_000);
    assert(emi.host.done("say -1090001") && emi.host.done("move 0"), "off she goes");
    foreach (point; 0 .. 9)
    {
        emi.host.walking = false;
        emi.raise(MovementDone(point));
        emi.run(250);
    }
    emi.run(40_000);
    assert(emi.host.done("say -1090006") && emi.host.times("summon 6207") == 9 && emi.host.done("dungeon 100 1"));
}
