/**
 * Razorfen Kraul (map 47): the ward around Agathelos, which falls when the last Death's Head Ward
 * Keeper dies (and stays down for the copy's life), and Willix the Importer, who is escorted out of
 * the kraul for "Willix the Importer" (quest 1144), two Raging Agamar charging him twice on the way.
 */
module dmangos.scripts.razorfenkraul;

import dmangos.script;

/// Creatures and objects of the kraul.
enum : uint
{
    wardKeeper = 4625,
    willix = 4508,
    ragingAgamar = 4514,
    agathelosWard = 21099,
}

/// What the kraul remembers: whether the ward is down (`instance.data`).
@instance("instance_razorfen_kraul")
struct RazorfenKraul
{
    bool wardDown;
    Pack!8 keepers;               /// the keepers, as they load; the last one's death drops the ward
    @transient EntityRef ward;

    void on(ref InstanceContext kraul, const ref ObjectLoaded e)
    {
        if (e.object.entry == agathelosWard)
        {
            ward = e.object;
            if (wardDown)
                kraul.door(e.object, true);
        }
    }

    void on(ref InstanceContext kraul, const ref CreatureLoaded e)
    {
        if (e.creature.entry == wardKeeper)
            keepers.add(e.creature);
    }

    void on(ref InstanceContext kraul, const ref CreatureDied e)
    {
        if (e.creature.entry != wardKeeper || wardDown)
            return;
        keepers.died(e.creature);
        if (keepers.allDead)
        {
            wardDown = true;
            kraul.log("the last ward keeper fell: Agathelos's ward is down");
            if (ward)
                kraul.door(ward, true);
        }
    }
}

/// `FactionTemplate`s an escorted creature takes (`FACTION_ESCORT_*`).
enum : uint
{
    escortNeutralPassive = 113,
    escortNeutralActive = 250,
}

/// Willix the Importer: see the module documentation.
@creature("npc_willix_the_importer")
struct Willix
{
    enum uint quest = 1144;
    enum : int
    {
        sayReady = -1047000, say1 = -1047001, say2 = -1047002, say3 = -1047003, say4 = -1047004,
        say5 = -1047005, say6 = -1047006, say7 = -1047007, sayEnd = -1047008, sayAggro1 = -1047009,
    }

    /// Where the boars come from: two on the path, two at its end.
    static immutable Location[4] boars = [
        Location(2151.420f, 1733.18f, 52.10f), Location(2144.463f, 1726.89f, 51.93f),
        Location(1956.433f, 1597.97f, 81.75f), Location(1958.971f, 1599.01f, 81.44f),
    ];

    Escort escort;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != quest || escort.active)
            return;
        escort.start(me, e.player, quest);
        me.say(sayReady, e.player);
        me.setFaction(escortNeutralPassive);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const pick = me.random(7); // not always said
        if (pick < 4)
            me.say(sayAggro1 - cast(int) pick, e.enemy);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        // The database's points count from 1.
        switch (escort.reached(me, e) + 1)
        {
        case 3: me.say(say1); break;
        case 7: me.say(say2); break;
        case 10: me.say(say3); break;
        case 15:
            me.say(say4);
            me.summon(ragingAgamar, boars[0], 25_000, me.self);
            me.summon(ragingAgamar, boars[1], 25_000, me.self);
            break;
        case 26: me.say(say5); break;
        case 34: me.say(say6); break;
        case 45:
            me.say(say7);
            me.summon(ragingAgamar, boars[2], 25_000, me.self);
            me.summon(ragingAgamar, boars[3], 25_000, me.self);
            break;
        case 46:
            me.say(sayEnd);
            me.questEvent(escort.player, quest);
            escort.paused = true; // he rests here, a quest giver again
            me.restoreNpcFlags();
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.setFaction(0);
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.razorfenkraul;
    auto kraul = runInstance!self("instance_razorfen_kraul");
    kraul.raise(ObjectLoaded(objectRef(agathelosWard)));
    kraul.raise(CreatureLoaded(creatureRef(wardKeeper, 1)));
    kraul.raise(CreatureLoaded(creatureRef(wardKeeper, 2)));
    kraul.raise(CreatureDied(creatureRef(wardKeeper, 1)));
    assert(!kraul.host.done("door 21099 open"), "one keeper still stands");
    kraul.raise(CreatureDied(creatureRef(wardKeeper, 2)));
    assert(kraul.host.done("door 21099 open"));
    // A restart: the ward loads down.
    kraul.host.forget();
    kraul.raise(ObjectLoaded(objectRef(agathelosWard)));
    assert(kraul.host.done("door 21099 open") && kraul.state!RazorfenKraul.wardDown);

    auto willix = runCreature!self("npc_willix_the_importer", self.willix);
    foreach (i; 0 .. 47)
        willix.host.path ~= Waypoint(Location(i, 0, 0));
    willix.raise(QuestAccepted(playerRef, Willix.quest));
    assert(willix.host.done("faction 113") && willix.host.done("move 0"));
    foreach (point; 0 .. 46)
    {
        willix.host.walking = false;
        willix.raise(MovementDone(point));
        willix.run(250);
    }
    assert(willix.host.times("summon 4514") == 4 && willix.host.done("quest event 1144"));
    assert(!willix.host.done("move 46"), "he rests at the end");
}
