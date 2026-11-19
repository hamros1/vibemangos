/**
 * Onyxia's Lair (map 249): the copy's script (Onyxia's encounter) and Onyxia herself, who fights on the
 * ground, takes to the air at two thirds of her health (fireballs, deep breaths across the lair, her
 * whelps pouring out of their nests) and lands at two fifths to fight to the end, roaring in fear.
 */
module dmangos.scripts.onyxia;

import core.time : Duration;

import dmangos.script;

/// Creatures of the lair.
enum : uint
{
    npcOnyxia = 10184,
    npcOnyxiaWhelp = 11262,
    npcOnyxiaTrigger = 12758, /// the middle of her lair
}

/// The copy's encounters: just hers, and when she took off.
enum OnyxiaData : uint
{
    onyxia = 0,
    liftoff = 4, /// a value of `onyxia`: she is in the air
}

/// What the copy remembers of Onyxia's fight.
@instance("instance_onyxias_lair")
struct OnyxiasLair
{
    EncounterState onyxia;
    bool inAir; /// her phase in the air began

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id != OnyxiaData.onyxia)
            return;
        if (e.value == OnyxiaData.liftoff)
        {
            inAir = true;
            return;
        }
        onyxia = cast(EncounterState) e.value;
        inAir = false;
        if (onyxia == EncounterState.done)
            copy.log("Onyxia is slain");
    }

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id == OnyxiaData.onyxia)
            copy.answer(inAir ? OnyxiaData.liftoff : onyxia);
    }
}

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/**
 * Onyxia. Phase one, on the ground: flame breath, cleave, tail sweep, wing buffet, knock away, and a deep
 * breath down the entrance if she is drawn out of her lair. At 65% she flies: fireballs at random, and
 * every so often a deep breath across the lair or a flight to a neighbouring spot, while whelps come.
 * At 40% she lands, and adds Bellowing Roar.
 */
@creature("boss_onyxia")
struct Onyxia
{
    enum : int
    {
        sayAggro = -1_249_000,
        sayKill = -1_249_001,
        sayPhase2 = -1_249_002,
        sayPhase3 = -1_249_003,
        emoteBreath = -1_249_004,
        sayKite = -1_249_005,
    }
    enum : uint
    {
        wingBuffet = 18500,
        flameBreath = 18435,
        cleave = 19983,
        tailSweep = 15847,
        knockAway = 19633,
        fireball = 18392,
        dragonHover = 18430,
        pacifySelf = 19951,
        breathEntrance = 21131,
        bellowingRoar = 18431,
        heatedGround = 22191,
    }

    /// Where she flies, and the deep breath she breathes from there (across to the point opposite).
    static struct Spot
    {
        uint breath;
        Location at;
    }

    static immutable Spot[8] spots = [
        Spot(17086, Location(24.16332f, -216.0808f, -58.98009f)),   // north
        Spot(18617, Location(10.2191f, -247.912f, -60.896f)),       // north-east
        Spot(18576, Location(-15.00505f, -244.4841f, -60.40087f)),  // east
        Spot(18564, Location(-63.5156f, -240.096f, -60.477f)),      // south-east
        Spot(18351, Location(-66.3589f, -215.928f, -64.23904f)),    // south
        Spot(18596, Location(-58.2509f, -189.020f, -60.790f)),      // south-west
        Spot(18609, Location(-16.70134f, -181.4501f, -61.98513f)),  // west
        Spot(18584, Location(12.26687f, -181.1084f, -60.23914f)),   // north-west
    ];
    enum ubyte north = 0, south = 4;
    static immutable landAt = Location(-1.060547f, -229.9293f, -86.14094f);
    static immutable liftoffAt = Location(-66.3589f, -215.928f, -84.25523f, 6.248279f);
    static immutable Location[2] whelpNests = [
        Location(-30.127f, -254.463f, -89.440f), Location(-30.817f, -177.106f, -89.258f)];

    /// Points of her `moveNow`s: the spots are 0 .. 7.
    enum : uint { pointLiftoff = 9, pointInitNorth = 10, pointLand = 11 }

    enum Phase : ubyte
    {
        start = 1,      /// on the ground, above 65%
        breath = 2,     /// in the air
        end = 3,        /// on the ground again
        breathPost = 4, /// landing
        toLiftoff = 5,  /// going to where she takes off
        breathPre = 6,  /// taking off, flying to the north end
    }

    enum Step : ubyte
    {
        checkInLair, bellowingRoar, flameBreath, cleave, tailSweep, wingBuffet, knockAway, fireball,
        movement, summonWhelps, transition, breathMove,
    }

    Schedule!(Step, 16) steps;
    Phase phase = Phase.start;
    ubyte movePoint;
    ubyte whelpsSummoned, whelpsPerWave = 20;
    bool yelledLured, firstWaveDone;
    EntityRef fireballVictim;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        rest(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        rest(me);
        me.signalDungeon(OnyxiaData.onyxia, EncounterState.failed);
    }

    /// Back as she was before the fight: asleep on the ground.
    private void rest(ref CreatureContext me)
    {
        steps.clear();
        phase = Phase.start;
        movePoint = north;
        whelpsSummoned = 0;
        whelpsPerWave = 20;
        yelledLured = firstWaveDone = false;
        me.flying(false);
        me.combatMovement(true);
        me.melee(true);
        me.standState(StandState.sleep);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
        me.flying(false);
        me.removeAura(pacifySelf);
        me.removeAura(dragonHover);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        me.signalDungeon(OnyxiaData.onyxia, EncounterState.inProgress);
        me.standState(StandState.stand);
        steps.after(Step.checkInLair, 3.seconds);
        steps.after(Step.flameBreath, between(me, 10_000, 20_000));
        steps.after(Step.cleave, between(me, 2000, 5000));
        steps.after(Step.tailSweep, between(me, 15_000, 20_000));
        steps.after(Step.wingBuffet, between(me, 10_000, 20_000));
        steps.after(Step.knockAway, between(me, 20_000, 30_000));
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.say(sayKill);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(OnyxiaData.onyxia, EncounterState.done);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (phase == Phase.start && e.after <= 65)
        {
            // Up she goes: to the south end of the lair first.
            phase = Phase.toLiftoff;
            me.say(sayPhase2);
            foreach (s; [Step.checkInLair, Step.flameBreath, Step.cleave, Step.tailSweep, Step.wingBuffet,
                    Step.knockAway, Step.bellowingRoar])
                steps.cancel(s);
            me.combatMovement(false);
            me.melee(false);
            me.moveNow(liftoffAt, pointLiftoff);
        }
        else if (phase == Phase.breath && e.after <= 40)
        {
            // Down she comes, for the end.
            phase = Phase.breathPost;
            me.say(sayPhase3);
            steps.cancel(Step.summonWhelps);
            steps.cancel(Step.fireball);
            steps.cancel(Step.movement);
            steps.cancel(Step.breathMove);
            me.removeAura(dragonHover);
            me.moveNow(landAt, pointLand);
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (!me.inCombat)
            return;
        switch (e.point)
        {
        case pointLand:
            me.emote(293); // EMOTE_ONESHOT_LAND
            me.flying(false);
            me.removeAura(pacifySelf);
            steps.after(Step.transition, 2.seconds);
            return;
        case pointLiftoff:
            steps.after(Step.transition, 3500.msecs);
            me.flying(true);
            me.emote(254); // EMOTE_ONESHOT_LIFTOFF
            break;
        case pointInitNorth:
            phase = Phase.breath;
            me.castSelf(dragonHover, true);
            me.castSelf(pacifySelf, true);
            steps.after(Step.fireball, 0.msecs);
            steps.after(Step.movement, 25.seconds);
            break;
        default:
            me.castSelf(dragonHover, true);
            break;
        }
        if (const middle = me.creatureNearby(npcOnyxiaTrigger, 200))
            me.face(middle);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.transition:
            if (phase == Phase.toLiftoff)
            {
                phase = Phase.breathPre;
                steps.after(Step.summonWhelps, 3.seconds);
                me.signalDungeon(OnyxiaData.onyxia, OnyxiaData.liftoff);
                me.moveNow(spots[north].at, pointInitNorth);
            }
            else if (phase == Phase.breathPost)
            {
                phase = Phase.end;
                me.combatMovement(true);
                me.melee(true);
                if (const victim = me.selectTarget(Pick.topThreat))
                    me.attack(victim);
                steps.after(Step.bellowingRoar, 0.msecs);
                steps.after(Step.flameBreath, between(me, 10_000, 20_000));
                steps.after(Step.cleave, between(me, 2000, 5000));
                steps.after(Step.tailSweep, between(me, 15_000, 20_000));
                steps.after(Step.knockAway, between(me, 10_000, 20_000));
                steps.after(Step.checkInLair, 3.seconds);
            }
            break;
        case Step.checkInLair:
            if (me.casting)
            {
                steps.after(step, retry);
                break;
            }
            const middle = me.creatureNearby(npcOnyxiaTrigger, 300);
            if (middle && me.distanceTo(middle) > 90)
            {
                // Drawn out of her lair: she breathes down the tunnel.
                if (!yelledLured)
                {
                    yelledLured = true;
                    me.say(sayKite);
                }
                me.castSelf(breathEntrance);
            }
            else
                yelledLured = false;
            steps.after(step, 3.seconds);
            break;
        case Step.bellowingRoar:
            steps.after(step, me.castSelf(bellowingRoar) == ActionResult.ok ? between(me, 15_000, 45_000) : retry);
            break;
        case Step.flameBreath:
            steps.after(step, me.castSpell(flameBreath) == ActionResult.ok ? between(me, 10_000, 20_000) : retry);
            break;
        case Step.cleave:
            steps.after(step, me.castSpell(cleave) == ActionResult.ok ? between(me, 5000, 10_000) : retry);
            break;
        case Step.tailSweep:
            steps.after(step, me.castSelf(tailSweep) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.wingBuffet:
            steps.after(step, me.castSelf(wingBuffet) == ActionResult.ok ? between(me, 15_000, 30_000) : retry);
            break;
        case Step.knockAway:
            steps.after(step, me.castSpell(knockAway) == ActionResult.ok ? between(me, 25_000, 40_000) : retry);
            break;
        case Step.fireball:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            if (target && me.castSpell(fireball, target) == ActionResult.ok)
            {
                // Whoever she fireballs she forgets: anyone may be next.
                if (fireballVictim)
                    me.modifyThreat(fireballVictim, -100);
                fireballVictim = target;
                steps.after(step, between(me, 3000, 5000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.movement:
            if (me.casting)
            {
                steps.after(step, retry);
                break;
            }
            final switch (me.random(3))
            {
            case 0: // a deep breath across the lair, flying to the far side
                me.say(emoteBreath);
                me.interrupt();
                me.castSelf(spots[movePoint].breath);
                movePoint = (movePoint + spots.length / 2) % spots.length;
                steps.after(Step.breathMove, 500.msecs);
                steps.after(step, 25.seconds);
                return;
            case 1: // to the spot on her left
                movePoint = cast(ubyte)((movePoint + spots.length - 1) % spots.length);
                break;
            case 2: // to the one on her right
                movePoint = cast(ubyte)((movePoint + 1) % spots.length);
                break;
            }
            steps.after(step, between(me, 15_000, 25_000));
            me.removeAura(dragonHover);
            me.moveNow(spots[movePoint].at, movePoint);
            break;
        case Step.breathMove:
            me.moveNow(spots[movePoint].at, movePoint);
            me.castSelf(heatedGround, true);
            break;
        case Step.summonWhelps:
            summonWhelps(me);
            break;
        }
    }

    /// A pair of whelps from the nests; after a wave, a pause until the next.
    private void summonWhelps(ref CreatureContext me)
    {
        if (whelpsSummoned >= whelpsPerWave)
        {
            const pause = 90_000 - whelpsPerWave * (firstWaveDone ? 3000 : 1750);
            steps.after(Step.summonWhelps, (pause > 0 ? pause : 1000).msecs);
            firstWaveDone = true;
            whelpsPerWave = cast(ubyte)(4 + me.random(7));
            whelpsSummoned = 0;
            return;
        }
        foreach (nest; whelpNests)
            if (me.summon(npcOnyxiaWhelp, nest, 3000, me.selectTarget(Pick.topThreat)))
                ++whelpsSummoned;
        steps.after(Step.summonWhelps, firstWaveDone ? between(me, 2000, 4000) : between(me, 1000, 2500));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptKind, ScriptRuntime;

    /// Onyxia as her script sees her.
    class FakeDragon : BlackHole!CreatureHost
    {
        uint[] casts;
        int[] said;
        Signal[] dungeon;
        bool fighting = true, flies, chases = true, swings = true, castingNow;
        Location[] flights;
        uint[] flightPoints;
        EntityRef[] whelps;
        StandState stand;

        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(npcOnyxia) << 24)); }
        override EntityRef hostVictim() { return EntityRef(7); }
        override bool hostInCombat() { return fighting; }
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override ActionResult hostSay(int text, EntityRef) { said ~= text; return ActionResult.ok; }
        override void hostSignalDungeon(uint id, int value) { dungeon ~= Signal(EntityRef.init, id, value); }
        override EntityRef hostSelectTarget(Pick, uint, uint) { return EntityRef(7); }
        override void hostFlying(bool on) { flies = on; }
        override void hostCombatMovement(bool on) { chases = on; }
        override void hostMelee(bool on) { swings = on; }
        override void hostMoveNow(Location at, uint point, bool) { flights ~= at; flightPoints ~= point; }
        override void hostStandState(StandState s) { stand = s; }
        override bool hostCasting() { return castingNow; }
        override float hostDistanceTo(EntityRef) { return 10; }
        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            whelps ~= EntityRef(0xF130_0000_0000_0000UL | (ulong(entry) << 24) | whelps.length);
            return whelps[$ - 1];
        }
    }
}

/// Onyxia's three phases: up at 65% (to the south end, then the north, whelps coming, fireballs), the
/// breaths and flights between spots, down at 40% (landing, then the ground fight with her roar).
unittest
{
    import std.algorithm.searching : canFind;

    alias self = dmangos.scripts.onyxia;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeDragon;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_onyxia");
    void run(int ms)
    {
        foreach (_; 0 .. ms / 100)
            runtime.tick(h, me, 100);
    }

    runtime.raise(h, me, Spawned());
    assert(host.stand == StandState.sleep);
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    assert(host.said == [Onyxia.sayAggro] && host.stand == StandState.stand);
    run(20_000);
    assert(host.casts.canFind(Onyxia.cleave) && host.casts.canFind(Onyxia.flameBreath));

    // 65%: she stops fighting and goes to the south end.
    runtime.raise(h, me, Damaged(EntityRef(7), 1000, 70, 64));
    assert(host.said[$ - 1] == Onyxia.sayPhase2 && !host.chases && !host.swings);
    assert(host.flightPoints == [Onyxia.pointLiftoff]);
    const castsBefore = host.casts.length;
    run(5000);
    assert(host.casts.length == castsBefore, "no ground abilities on the way");
    runtime.raise(h, me, MovementDone(Onyxia.pointLiftoff));
    assert(host.flies);
    run(3500);
    assert(host.flightPoints[$ - 1] == Onyxia.pointInitNorth);
    assert(host.dungeon.canFind(Signal(EntityRef.init, OnyxiaData.onyxia, OnyxiaData.liftoff)));
    run(3000);
    assert(host.whelps.length == 2, "the first whelps");
    runtime.raise(h, me, MovementDone(Onyxia.pointInitNorth));
    assert(host.casts.canFind(Onyxia.pacifySelf));
    run(5000);
    assert(host.casts.canFind(Onyxia.fireball));
    run(30_000);
    assert(host.flightPoints.length > 2 || host.said.canFind(Onyxia.emoteBreath), "she moves about the lair");
    assert(host.whelps.length >= 20, "a wave of twenty");

    // 40%: she lands.
    runtime.raise(h, me, Damaged(EntityRef(7), 1000, 41, 39));
    assert(host.said[$ - 1] == Onyxia.sayPhase3 && host.flightPoints[$ - 1] == Onyxia.pointLand);
    const whelps = host.whelps.length;
    runtime.raise(h, me, MovementDone(Onyxia.pointLand));
    assert(!host.flies);
    run(2000);
    assert(host.chases && host.swings && host.casts[$ - 1] == Onyxia.bellowingRoar);
    run(10_000);
    assert(host.whelps.length == whelps, "no more whelps");

    // A wipe: home, asleep, and the copy is told.
    runtime.raise(h, me, Evaded());
    runtime.raise(h, me, Reset());
    assert(host.stand == StandState.sleep && !host.flies);
    assert(host.dungeon[$ - 1] == Signal(EntityRef.init, OnyxiaData.onyxia, EncounterState.failed));
}
