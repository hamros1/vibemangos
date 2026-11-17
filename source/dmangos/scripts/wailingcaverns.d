/**
 * Wailing Caverns (map 43): the Fanglords' deaths, and the Disciple of Naralex's awakening of
 * Naralex. Once the four Fanglords are slain, the disciple leads the players through the caverns to
 * Naralex (his escort path, `waypoint_path` 3678), fighting off two ambushes on the way; there he
 * performs the awakening ritual while Naralex's nightmares come out of the water, Mutanus the
 * Devourer last. With Mutanus dead, Naralex wakes, and both go.
 */
module dmangos.scripts.wailingcaverns;

import dmangos.script;

/// Creatures of the caverns.
enum : uint
{
    cobrahn = 3669,
    pythas = 3670,
    anacondra = 3671,
    serpentis = 3673,
    disciple = 3678,
    naralex = 3679,
    mutanus = 3654,
    ravager = 3636,
    viper = 5755,
    moccasin = 5762,
    ectoplasm = 5763,
}

/// What the caverns remember: the Fanglords slain, and whether Naralex is awake (`instance.data`).
@instance("instance_wailing_caverns")
struct WailingCaverns
{
    enum Signals : uint { fanglordsSlain = 1, mutanusSlain = 2 }

    bool[4] fanglordDead;
    bool naralexAwake;
    @transient EntityRef discipleRef;

    private static immutable uint[4] fanglords = [cobrahn, pythas, anacondra, serpentis];

    private bool allSlain() const
    {
        foreach (dead; fanglordDead)
            if (!dead)
                return false;
        return true;
    }

    void on(ref InstanceContext caverns, const ref CreatureLoaded e)
    {
        if (e.creature.entry == disciple)
        {
            discipleRef = e.creature;
            if (allSlain() && !naralexAwake)
                caverns.signal(e.creature, Signals.fanglordsSlain);
        }
    }

    void on(ref InstanceContext caverns, const ref CreatureDied e)
    {
        foreach (i, entry; fanglords)
            if (e.creature.entry == entry && !fanglordDead[i])
            {
                fanglordDead[i] = true;
                if (allSlain() && discipleRef)
                    caverns.signal(discipleRef, Signals.fanglordsSlain);
            }
        if (e.creature.entry == mutanus && !naralexAwake)
        {
            naralexAwake = true;
            if (discipleRef)
                caverns.signal(discipleRef, Signals.mutanusSlain);
        }
    }
}

/// The Disciple of Naralex: see the module documentation.
@creature("npc_disciple_of_naralex")
struct DiscipleOfNaralex
{
    enum uint beginEvent = 1;
    /// `broadcast_text` rows.
    enum : uint
    {
        canBeAwakened = 2101, preparations = 1255, mustContinue = 1257, purified = 1259, downThisWay = 1260,
        beyondCorridor = 1263, protectMe = 1264, beginsRitual = 1265, awakes = 1267, attacked = 1273,
        cantHandle = 1275, tosses = 1268, writhes = 1269, horrendousVision = 1270, iAmAwake = 1271,
        thanks = 1272,
    }
    /// Points of his path (0-based): the stops the database marks.
    enum : uint { firstWave = 11, afterFirstWave = 12, secondWave = 29, thirdStop = 56, naralexReached = 69 }

    enum Step : ubyte { tosses, moccasins, writhes, ectoplasm, vision, mutanus, awake, thanks, leave }
    Schedule!Step steps;
    Escort escort;
    bool fanglordsSlain, ritual, done;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == WailingCaverns.Signals.fanglordsSlain && !fanglordsSlain)
        {
            fanglordsSlain = true;
            me.sayText(canBeAwakened);
        }
        else if (e.id == WailingCaverns.Signals.mutanusSlain && ritual)
            steps.after(Step.awake, 2.seconds);
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!fanglordsSlain || escort.active || ritual || done)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Let the event begin!", beginEvent);
        me.sendGossip(e.player, 0, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != beginEvent || escort.active || ritual || done)
            return;
        me.closeGossip(e.player);
        escort.start(me, e.player, 0);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e))
        {
        case 0:
            me.sayText(preparations);
            me.emote(1); // talk
            break;
        case firstWave:
            wave(me, ravager, 2);
            break;
        case afterFirstWave:
            me.emote(25); // point
            me.sayText(mustContinue);
            break;
        case secondWave:
            wave(me, viper, 3);
            break;
        case thirdStop:
            me.emote(25);
            me.sayText(beyondCorridor);
            break;
        case naralexReached:
            // The ritual: he stops here (his path goes on only when Naralex is awake).
            escort.active = false;
            ritual = true;
            me.sayText(protectMe);
            me.sayText(beginsRitual);
            steps.after(Step.tosses, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        const naralexRef = me.creatureNearby(naralex, 40);
        final switch (step)
        {
        case Step.tosses:
            me.sayAs(naralexRef, tosses);
            steps.after(Step.moccasins, 5.seconds);
            break;
        case Step.moccasins:
            wave(me, moccasin, 3);
            steps.after(Step.writhes, 30.seconds);
            break;
        case Step.writhes:
            me.sayAs(naralexRef, writhes);
            steps.after(Step.ectoplasm, 5.seconds);
            break;
        case Step.ectoplasm:
            wave(me, ectoplasm, 5);
            steps.after(Step.vision, 30.seconds);
            break;
        case Step.vision:
            me.sayAs(naralexRef, horrendousVision);
            steps.after(Step.mutanus, 5.seconds);
            break;
        case Step.mutanus:
            wave(me, mutanus, 1);
            break;
        case Step.awake:
            me.sayAs(naralexRef, iAmAwake);
            me.sayText(awakes);
            steps.after(Step.thanks, 5.seconds);
            break;
        case Step.thanks:
            me.sayAs(naralexRef, thanks);
            steps.after(Step.leave, 10.seconds);
            break;
        case Step.leave:
            ritual = false;
            done = true;
            me.despawn(naralexRef, 0);
            me.despawn(1000);
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (escort.active || ritual)
            me.sayText(me.random(2) ? attacked : cantHandle, e.enemy);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        ritual = false;
        steps.clear();
    }

    /// `count` creatures of `entry` around him, set on whoever he walks with.
    private void wave(ref CreatureContext me, uint entry, uint count)
    {
        import std.math : cos, sin;

        const at = me.location;
        foreach (i; 0 .. count)
        {
            const angle = i * 6.2832f / count;
            me.summon(entry, Location(at.x + 6 * cos(angle), at.y + 6 * sin(angle), at.z, at.orientation), 0,
                escort.player);
        }
    }
}
