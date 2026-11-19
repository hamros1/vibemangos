/**
 * The Hinterlands: two escorts. The robot chicken OOX-09/HL, repaired on "Rescue OOX-09/HL!" (836),
 * walks home past an owl and a troll ambush; Rin'ji, freed from his cage on "Rin'ji is Trapped!"
 * (2742), runs from the Quel'Danil Lodge past two Highvale ambushes.
 */
module dmangos.scripts.hinterlands;

import std.math : cos, sin;
import dmangos.script;

/// `UnitFlags.immuneToNpc`.
private enum uint immuneToNpc = 0x200;

/// A spot within `radius` yards of `center`, at random.
private Location around(ref CreatureContext me, Location center, float radius)
{
    const angle = me.random(360) * 0.0174533f, distance = me.random(cast(uint)(radius * 10) + 1) / 10.0f;
    return Location(center.x + distance * cos(angle), center.y + distance * sin(angle), center.z, center.orientation);
}

/**
 * OOX-09/HL: lying broken until the quest is taken; then it gets up and walks (`script_waypoint`,
 * points counted from 1). At two points it warns of danger and three Marauding Owls, then three Vile
 * Ambushers come at it; at the last the quest's event happens. If it is destroyed, its ambushers go
 * and the quest fails.
 */
@creature("npc_00x09hl")
struct Oox09
{
    enum uint questRescueOox09 = 836, maraudingOwl = 7808, vileAmbusher = 7809;
    enum uint factionEscortNeutralFriendActive = 495;
    enum : int { sayStart = -1000287, sayAggro1 = -1000288, sayAggro2 = -1000289, sayAmbush = -1000290, sayEnd = -1000292 }
    enum : uint { owlPoint = 27, ambusherPoint = 44, endPoint = 65 }

    Escort escort = { despawnAfterMs: 5000 };
    EntityRef[6] ambushers;
    ubyte summoned;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!escort.active)
            me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questRescueOox09 || escort.active)
            return;
        me.say(sayStart, e.player);
        me.standState(StandState.stand);
        me.setFaction(factionEscortNeutralFriendActive);
        me.unitFlags(immuneToNpc, false);
        summoned = 0;
        ambushers[] = EntityRef.init;
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case owlPoint:
            me.say(sayAmbush);
            ambush(me, maraudingOwl, Location(147.927444f, -3851.513428f, 130.893f), 3);
            break;
        case ambusherPoint:
            me.say(sayAmbush);
            ambush(me, vileAmbusher, Location(-141.151581f, -4291.213867f, 120.130f), 6);
            break;
        case endPoint:
            me.say(sayEnd);
            me.questEvent(escort.player, escort.quest);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (e.enemy.entry != maraudingOwl && e.enemy.entry != vileAmbusher)
            me.say(me.random(2) ? sayAggro1 : sayAggro2);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        foreach (a; ambushers[0 .. summoned])
            me.despawn(a, 0);
        escort.fail(me);
    }

    /// Three of `entry` around `center`, coming for it (until `upTo` have come on this escort).
    private void ambush(ref CreatureContext me, uint entry, Location center, ubyte upTo)
    {
        while (summoned < upTo)
            ambushers[summoned++] = me.summon(entry, around(me, center, 7), 25_000, me.self);
    }
}

/**
 * Rin'ji: freed (his cage opens as the quest is taken), he runs his path (`script_waypoint`, points
 * counted from 1); twice a Highvale Ranger and two Outrunners come out and run at him; at the end the
 * quest's event happens, and a little later he tells the player what to do next.
 */
@creature("npc_rinji")
struct Rinji
{
    enum uint questRinjiTrapped = 2742, ranger = 2694, outrunner = 2691, cage = 142036;
    enum : int
    {
        sayFree = -1000403, sayByOutrunner = -1000404, sayHelp1 = -1000405, sayHelp2 = -1000406,
        sayComplete = -1000407, sayProgress1 = -1000408, sayProgress2 = -1000409,
    }
    enum : uint { freePoint = 2, firstAmbush = 8, secondAmbush = 14, endPoint = 18 }

    private static immutable Location[2] ambushFrom = [Location(191.29620f, -2839.329346f, 107.388f),
        Location(70.972466f, -2848.674805f, 109.459f)];
    private static immutable Location[2] ambushTo = [Location(166.63038f, -2824.780273f, 108.153f),
        Location(70.886589f, -2874.335449f, 116.675f)];

    enum Step : ubyte { progress1, progress2 }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 5000 };
    bool byOutrunner; /// an Outrunner has had its say

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questRinjiTrapped || escort.active)
            return;
        if (const c = me.objectNearby(cage, 5))
            me.useObject(c);
        byOutrunner = false;
        escort.start(me, e.player, e.quest);
        me.unitFlags(immuneToNpc, false);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const player = escort.player;
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case freePoint:
            me.say(sayFree, player);
            break;
        case firstAmbush:
            ambush(me, 0);
            break;
        case secondAmbush:
            ambush(me, 1);
            break;
        case endPoint:
            me.say(sayComplete, player);
            me.questEvent(player, escort.quest);
            escort.run = true;
            steps.after(Step.progress1, 3.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat) // after the fight
            return cast(void) steps.after(step, 3.seconds);
        final switch (step)
        {
        case Step.progress1:
            me.say(sayProgress1, escort.player);
            steps.after(Step.progress2, 3.seconds);
            break;
        case Step.progress2:
            me.say(sayProgress2, escort.player);
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        me.attack(e.summoned, me.self); // at the spot: at him
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!escort.active)
            return;
        if (e.enemy.entry == outrunner && !byOutrunner)
        {
            me.sayOther(e.enemy, sayByOutrunner);
            byOutrunner = true;
        }
        if (me.random(4) == 0)
            me.say(me.random(2) ? sayHelp1 : sayHelp2);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        escort.fail(me);
    }

    /// A ranger and two outrunners come out at `spot` and run to where he passes.
    private void ambush(ref CreatureContext me, size_t spot)
    {
        static immutable uint[3] party = [ranger, outrunner, outrunner];
        foreach (entry; party)
            if (const a = me.summon(entry, ambushFrom[spot], 60_000))
                me.moveCreature(a, ambushTo[spot], 1, true);
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.hinterlands;
    auto oox = Driven!zone.make("npc_00x09hl");
    oox.raise(Spawned());
    assert(oox.host.did("stand 7"));
    oox.host.pathLength = 65;
    oox.raise(QuestAccepted(oox.host.player, 836));
    assert(oox.host.faction == 495 && oox.host.did("stand 0"));
    oox.walk(43);
    assert(oox.host.summons == 6);
    oox.raise(Died());
    assert(oox.host.did("despawn other 7809") && oox.host.did("fail 836"));

    auto rinji = Driven!zone.make("npc_rinji");
    rinji.host.pathLength = 24;
    rinji.host.nearby[142036] = EntityRef(0xF110_0000_0000_0000 | (ulong(142036) << 24) | 1);
    rinji.raise(QuestAccepted(rinji.host.player, 2742));
    assert(rinji.host.did("use 142036") && rinji.host.did("flags off 512"));
    rinji.walk(7);
    assert(rinji.host.did("summon 2694") && rinji.host.did("move other 2691 1"));
    rinji.raise(SummonedArrived(creatureRef(2691), 1));
    assert(rinji.host.did("attack 2691 1"));
    rinji.walk(17);
    assert(rinji.host.did("event 2742"));
    rinji.tick(6000);
    assert(rinji.host.did("say -1000409"));
}
