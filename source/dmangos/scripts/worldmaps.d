/**
 * The continents' own scripts (ScriptDevAI's `world_map_scripts`, `world_kalimdor`): the events of
 * Kalimdor no single creature owns. "Wanted: Murkdeep!" (4740): the Greymist come in three waves to the
 * Darkshore beach where the trigger called them, Murkdeep with the last. Omen (the Lunar Festival): after
 * thirty rockets of Moonglade's clusters he rises from the lake, his minions perhaps before him.
 */
module dmangos.scripts.worldmaps;

import dmangos.script;

/// The signals Kalimdor's script hears (`signalDungeon` on the continent).
enum KalimdorSignal : uint { murkdeepCalled = 1, rocketLaunched }

/// Kalimdor's script (`world_map_kalimdor`).
@world("world_map_kalimdor")
struct KalimdorMap
{
    enum : uint { npcGreymistCoastrunner = 2202, npcGreymistWarrior = 2205, npcGreymistHunter = 2206,
        npcMurkdeep = 10323, npcMinionOfOmen = 15466, npcOmen = 15467, spellOmenMoonlight = 26392, maxRockets = 30 }

    private enum Location murkdeepSpawn = Location(4981.031f, 597.955f, -1.361f, 4.82f),
        murkdeepMove = Location(4988.970f, 547.002f, 5.379f), omenSpawn = Location(7564.098f, -2835.687f, 447.374f, 3.98f),
        omenMove = Location(7528.430f, -2889.838f, 459.365f);
    private static immutable Location[7] minionSpawns = [Location(7669.430f, -2869.980f, 464.904f, 2.60f),
        Location(7621.790f, -2861.740f, 459.043f, 4.15f), Location(7597.130f, -2885.880f, 464.898f, 2.88f),
        Location(7594.170f, -2856.490f, 459.403f, 3.17f), Location(7477.750f, -2849.020f, 464.466f, 0.14f),
        Location(7507.560f, -2818.230f, 459.486f, 4.63f), Location(7558.880f, -2856.770f, 457.684f, 4.31f)];

    enum Step : ubyte { omenReset, moonlight }
    Schedule!Step steps;

    ubyte murkdeepKilled;        /// of the wave on the beach
    ubyte rockets;               /// launched since Omen last went
    EncounterState omen;         /// notStarted, special (his minions came), inProgress (he came), done (he fell)
    EntityRef omenRef;

    void on(ref WorldMapContext w, const ref Signal e)
    {
        switch (e.id)
        {
        case KalimdorSignal.murkdeepCalled:
            murkdeepKilled = 0;
            foreach (_; 0 .. 3)
                comeAshore(w, npcGreymistCoastrunner);
            break;
        case KalimdorSignal.rocketLaunched:
            if (++rockets < maxRockets)
            {
                // A chance (one in two) of his minions, once, before he comes.
                if (omen == EncounterState.notStarted && w.random(2) == 0)
                {
                    omen = EncounterState.special;
                    foreach (at; minionSpawns)
                        w.summon(npcMinionOfOmen, at, 15 * 60_000);
                }
            }
            else if (omen != EncounterState.inProgress && omen != EncounterState.done)
            {
                omenRef = w.summon(npcOmen, omenSpawn, 15 * 60_000);
                if (omenRef)
                {
                    omen = EncounterState.inProgress;
                    w.moveTo(omenRef, omenMove, 1);
                    steps.after(Step.omenReset, 15 * 60.seconds); // gone if nobody fights him
                }
            }
            break;
        default:
            break;
        }
    }

    void on(ref WorldMapContext w, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case npcGreymistCoastrunner:
            if (e.summoned && ++murkdeepKilled == 3) // the three of the first wave: two warriors
            {
                murkdeepKilled = 0;
                foreach (_; 0 .. 2)
                    comeAshore(w, npcGreymistWarrior);
            }
            break;
        case npcGreymistWarrior:
            if (e.summoned && ++murkdeepKilled == 2) // then Murkdeep himself, and a hunter
            {
                murkdeepKilled = 0;
                comeAshore(w, npcMurkdeep);
                comeAshore(w, npcGreymistHunter);
            }
            break;
        case npcOmen:
            omen = EncounterState.done;
            steps.after(Step.moonlight, 5.seconds);       // the quest's moonlight
            steps.after(Step.omenReset, 5 * 60.seconds);  // not again for five minutes
            break;
        default:
            break;
        }
    }

    void on(ref WorldMapContext w, Step step)
    {
        final switch (step)
        {
        case Step.moonlight:
            w.castSpell(omenRef, spellOmenMoonlight);
            break;
        case Step.omenReset:
            if (omen == EncounterState.inProgress && w.victimOf(omenRef))
                return cast(void) steps.after(Step.omenReset, 10.seconds); // he fights: not now
            if (omenRef && w.alive(omenRef))
                w.despawn(omenRef);
            omenRef = EntityRef.init;
            omen = EncounterState.notStarted;
            rockets = 0;
            break;
        }
    }

    /// One of the Greymist comes out of the sea and runs up the beach.
    private void comeAshore(ref WorldMapContext w, uint entry)
    {
        const who = w.summon(entry, near(w, murkdeepSpawn, 5));
        if (who)
            w.moveTo(who, near(w, murkdeepMove, 5), 0, true);
    }

    private static Location near(ref WorldMapContext w, Location at, uint range)
    {
        import std.math : cos, sin, PI;

        const angle = w.random(360) * PI / 180, distance = w.random(range + 1);
        return Location(at.x + distance * cos(angle), at.y + distance * sin(angle), at.z, at.orientation);
    }
}

/// The Darkshore beach of "Wanted: Murkdeep!": one on the quest calls the Greymist ashore, unless they are already there.
@areaTrigger("at_murkdeep")
struct MurkdeepBeach
{
    enum uint questWantedMurkdeep = 4740;

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (at.questStatus(e.player, questWantedMurkdeep) != QuestProgress.incomplete)
            return;
        Location here;
        if (!at.locationOf(e.player, here))
            return;
        at.consume();
        // (Not the warriors: the world database spawns four on the beach, and asking for none of them near kept the
        // event from ever starting; ScriptDev asks only for Murkdeep and the coastrunners.)
        if (at.creatureNear(KalimdorMap.npcMurkdeep, here, 100) || at.creatureNear(KalimdorMap.npcGreymistCoastrunner, here, 60))
            return; // the event is on
        at.signalDungeon(KalimdorSignal.murkdeepCalled);
    }
}

/// A Cluster Launcher of Moonglade (the Lunar Festival): every launch counts towards Omen's rising.
@gameObject("go_omen_cluster")
struct OmenCluster
{
    void on(ref GameObjectContext it, const ref ObjectUsed e)
    {
        it.signalDungeon(KalimdorSignal.rocketLaunched);
    }
}

unittest
{
    import dmangos.script.registry : ScriptKind, ScriptRuntime;
    import dmangos.scripts.testing : creatureRef, TestInstance;

    alias self = dmangos.scripts.worldmaps;

    auto runtime = ScriptRuntime.of!self();
    auto host = new TestInstance;
    auto handle = runtime.create(ScriptKind.world, "world_map_kalimdor");
    assert(handle);
    void raise(E)(E e)
    {
        auto w = WorldMapContext(host);
        runtime.raise(handle, w, e);
    }

    // Murkdeep: three coastrunners, two warriors, then he comes.
    raise(Signal(EntityRef.init, KalimdorSignal.murkdeepCalled));
    assert(host.times("summon 2202") == 3 && host.times("move 2202 0") == 3);
    raise(CreatureDied(creatureRef(2202, 9), EntityRef(7), false));
    foreach (spawn; 1001 .. 1004)
        raise(CreatureDied(creatureRef(2202, spawn), EntityRef(7), true));
    assert(host.times("summon 2205") == 2, "the map's own coastrunner counts for nothing");
    raise(CreatureDied(creatureRef(2205, 1004), EntityRef(7), true));
    raise(CreatureDied(creatureRef(2205, 1005), EntityRef(7), true));
    assert(host.done("summon 10323") && host.done("summon 2206"));

    // Omen comes at the thirtieth rocket.
    foreach (_; 0 .. 29)
        raise(Signal(EntityRef.init, KalimdorSignal.rocketLaunched));
    assert(host.times("summon 15466") == 7 && !host.done("summon 15467"), "his minions came, once");
    raise(Signal(EntityRef.init, KalimdorSignal.rocketLaunched));
    assert(host.done("summon 15467") && host.done("move 15467 1"));
}
