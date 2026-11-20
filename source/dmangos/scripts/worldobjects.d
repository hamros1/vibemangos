/**
 * Objects, events, items and area triggers found all over the world (ScriptDevAI's `go_scripts`,
 * `item_scripts`, `areatrigger_scripts` and the zones' own): the city bells, the Darkmoon Faire's music,
 * the elemental rifts, the dragon heads raised over the cities, Thrall's stake, Azshara's lightning and
 * Maws' buoy, the Venture Co. wagon, the traps only some set off, the Wildhammer message, the Orb of
 * Draconic Energy, the Winter Wondervolt, the Hive'Ashi tower and the Stormwind recruiter.
 */
module dmangos.scripts.worldobjects;

import dmangos.script;

// ---------------------------------------------------------------------------
// Game objects
// ---------------------------------------------------------------------------

/**
 * A city's bell: on the hour it tolls the hour (one to twelve strokes, three seconds apart), with the
 * sound of its people, heard by those near it.
 */
@gameObject("go_bells")
struct Bells
{
    enum : uint { hordeBell = 175885, allianceBell = 176573 }
    enum : uint { tollTribal = 6595, tollHorde = 6675, tollAlliance = 6594, tollNightElf = 6674, tollDwarfGnome = 7234 }
    enum : uint { areaTarrenMill = 272, areaIronforge1 = 809, areaBrill = 2118, areaUndercity = 1497,
        areaIronforge2 = 1537, areaDarnassus = 1657 }

    enum Step : ubyte { watch, toll }
    Schedule!Step steps;
    ubyte lastHour = ubyte.max; /// the hour it last tolled (or came into the world in)
    ubyte tollsLeft;

    void on(ref GameObjectContext it, const ref Spawned e)
    {
        lastHour = cast(ubyte)(it.minuteOfDay / 60);
        steps.every(Step.watch, 30.seconds);
    }

    void on(ref GameObjectContext it, Step step)
    {
        final switch (step)
        {
        case Step.watch:
            const hour = cast(ubyte)(it.minuteOfDay / 60);
            if (hour == lastHour)
                return;
            lastHour = hour;
            tollsLeft = cast(ubyte)(hour % 12 == 0 ? 12 : hour % 12);
            goto case Step.toll;
        case Step.toll:
            if (tollsLeft == 0)
                return;
            it.playSound(soundOf(it.self.entry, it.areaId));
            if (--tollsLeft)
                steps.after(Step.toll, 3.seconds);
            break;
        }
    }

    /// The toll of a bell of `entry` standing in `area`.
    static uint soundOf(uint entry, uint area) pure nothrow @nogc @safe
    {
        if (entry == hordeBell)
            return area == areaUndercity || area == areaBrill || area == areaTarrenMill ? tollTribal : tollHorde;
        if (area == areaIronforge1 || area == areaIronforge2)
            return tollDwarfGnome;
        return area == areaDarnassus ? tollNightElf : tollAlliance;
    }
}

/// The Darkmoon Faire's music, played again every five seconds.
@gameObject("go_darkmoon_faire_music")
struct DarkmoonFaireMusic
{
    enum uint musicDarkmoonFaire = 8440;

    enum Step : ubyte { play }
    Schedule!Step steps;

    void on(ref GameObjectContext it, const ref Spawned e)
    {
        steps.every(Step.play, 5.seconds);
    }

    void on(ref GameObjectContext it, Step step)
    {
        it.playSound(musicDarkmoonFaire, true);
    }
}

/// An elemental rift of the invasions: every thirty seconds an invader comes out, while fewer than three are near.
@gameObject("go_elemental_rift")
struct ElementalRift
{
    enum Step : ubyte { spawn }
    Schedule!Step steps;

    /// The invader of each rift.
    static uint invaderOf(uint rift) pure nothrow @nogc @safe
    {
        switch (rift)
        {
        case 179664: return 14462; // earth: Thundering Invader
        case 179665: return 14458; // water: Watery Invader
        case 179666: return 14460; // fire: Blazing Invader
        case 179667: return 14455; // air: Whirling Invader
        default: return 0;
        }
    }

    void on(ref GameObjectContext it, const ref Spawned e)
    {
        steps.every(Step.spawn, (it.random(30_001)).msecs, 30.seconds);
    }

    void on(ref GameObjectContext it, Step step)
    {
        const invader = invaderOf(it.self.entry);
        EntityRef[3] near;
        if (invader == 0 || it.creaturesNearby(invader, 35, near[]) >= near.length)
            return;
        // A random point within 25 yards (`GetRandomPoint`).
        import std.math : cos, sin, PI;

        auto at = it.location;
        const angle = it.random(360) * PI / 180, distance = it.random(26);
        at.x += distance * cos(angle);
        at.y += distance * sin(angle);
        it.summon(invader, at);
    }
}

/// The severed head of Onyxia or Nefarian raised over a city: the city's leader near it cries the
/// Rallying Cry of the Dragonslayer.
@gameObject("go_dragon_head")
struct DragonHead
{
    enum uint spellRallyingCry = 22888;

    void on(ref GameObjectContext it, const ref Spawned e)
    {
        uint leader;
        switch (it.self.entry)
        {
        case 179556: leader = 14392; break; // Onyxia, Horde: Overlord Runthak
        case 179558: leader = 14394; break; // Onyxia, Alliance: Major Mattingly
        case 179881: leader = 14720; break; // Nefarian, Horde: High Overlord Saurfang
        case 179882: leader = 14721; break; // Nefarian, Alliance: Field Marshal Afrasiabi
        default: return;
        }
        if (const caster = it.creatureNearby(leader, 30))
            it.castSpell(caster, spellRallyingCry, caster);
    }
}

/// The Unadorned Stake in Orgrimmar: the head put on it, Thrall gives the Warchief's Blessing.
@gameObject("go_unadorned_spike")
struct UnadornedSpike
{
    enum : uint { npcThrall = 4949, spellWarchiefsBlessing = 16609 }

    void on(ref GameObjectContext it, const ref ObjectUsed e)
    {
        if (const thrall = it.creatureNearby(npcThrall, 30))
            it.castSpell(thrall, spellWarchiefsBlessing, thrall);
    }
}

/// Azshara's Theatric Lightning: it flashes every two to five seconds.
@gameObject("go_lightning")
struct Lightning
{
    enum Step : ubyte { flash }
    Schedule!Step steps;

    void on(ref GameObjectContext it, const ref Spawned e)
    {
        steps.after(Step.flash, (2000 + 1000 * it.random(4)).msecs);
    }

    void on(ref GameObjectContext it, Step step)
    {
        it.customAnim();
        steps.after(Step.flash, (2000 + 1000 * it.random(4)).msecs);
    }
}

/**
 * The Venture Co. wagon of Covert Ops: when its trap goes off, the Venture Co. near come running to it,
 * and three quarters of a minute later go back to their work.
 */
@gameObject("go_covert_ops")
struct CovertOps
{
    private static immutable uint[5] ventureCo = [3991, 3989, 3999, 4004, 3988]; // deforester, logger, digger, overlord, operator

    enum Step : ubyte { call, sendBack }
    Schedule!Step steps;
    EntityRef[24] called;
    ubyte calledCount;

    void on(ref GameObjectContext it, const ref TrapSprung e)
    {
        if (steps.busy)
            return;
        calledCount = 0;
        foreach (entry; ventureCo)
            calledCount += it.creaturesNearby(entry, 100, called[calledCount .. $]);
        steps.after(Step.call, 2.seconds);
    }

    void on(ref GameObjectContext it, Step step)
    {
        import std.math : cos, sin, PI;

        final switch (step)
        {
        case Step.call:
            // Around the wagon, ten yards off it.
            const wagon = it.location;
            foreach (i, who; called[0 .. calledCount])
            {
                const angle = 2 * PI * i / calledCount;
                it.moveCreature(who, Location(wagon.x + 10 * cos(angle), wagon.y + 10 * sin(angle), wagon.z), 1);
            }
            steps.after(Step.sendBack, 45.seconds);
            break;
        case Step.sendBack:
            foreach (who; called[0 .. calledCount])
                it.sendHome(who);
            calledCount = 0;
            break;
        }
    }
}

/// A trap that goes off only for those carrying `item` (`pTrapSearching`): the others pass.
private void onlyFor(ref GameObjectContext it, const ref TrapSprung e, uint item)
{
    if (!e.unit.isPlayer || !it.hasItem(e.unit, item))
        it.consume();
}

/// The Booty Bay transpolyporter: it carries only those with a Goblin Transponder.
@gameObject("go_transpolyporter_bb")
struct TranspolyporterBootyBay
{
    void on(ref GameObjectContext it, const ref TrapSprung e) { onlyFor(it, e, 9173); }
}

/// The Rune of the Defiler: it takes only those with a Ward of the Defiler.
@gameObject("go_rune_of_the_defiler")
struct RuneOfTheDefiler
{
    void on(ref GameObjectContext it, const ref TrapSprung e) { onlyFor(it, e, 10_757); }
}

// ---------------------------------------------------------------------------
// Scripted events
// ---------------------------------------------------------------------------

/// The Arcanite Buoy of Azshara: Maws comes up out of the sea (once), and the lightning flashes.
@scriptedEvent("event_arcanite_buoy")
struct ArcaniteBuoy
{
    enum : uint { npcMaws = 15571, goTheatricLightning = 183356 }
    private enum Location mawsSpawn = Location(3561.73f, -6647.2f, -7.5f, 1.6f);

    void on(ref EventContext e, const ref EventStarted ev)
    {
        Location at;
        if (!ev.source.isPlayer || !e.locationOf(ev.source, at))
            return;
        e.consume();
        if (e.creatureNear(npcMaws, at, 200))
            return; // not twice
        if (e.summon(npcMaws, mawsSpawn))
            e.respawnObjectsNear(goTheatricLightning, at, 20, 9);
    }
}

/// The Wildhammer message read: its reader is flagged for PvP.
@scriptedEvent("event_wildhammer_message")
struct WildhammerMessage
{
    void on(ref EventContext e, const ref EventStarted ev)
    {
        e.consume();
        if (ev.source.isPlayer)
            e.flagForPvP(ev.source);
    }
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

/// The Orb of Draconic Energy: it takes Emberstrife's soul only when he is near death and not yet taken.
@item("item_orb_of_draconic_energy")
struct OrbOfDraconicEnergy
{
    enum : uint { spellDominionSoul = 16053, npcEmberstrife = 10321 }

    void on(ref ItemContext it, const ref ItemUsed e)
    {
        Location at;
        if (!it.locationOf(e.player, at))
            return;
        const emberstrife = it.creatureNear(npcEmberstrife, at, 20);
        if (!emberstrife)
            return; // the spell finds no target by itself
        if (it.hasAura(emberstrife, spellDominionSoul) || it.healthPercentOf(emberstrife) > 10)
            it.consume();
    }
}

// ---------------------------------------------------------------------------
// Area triggers
// ---------------------------------------------------------------------------

/// The PX-238 Winter Wondervolt: one not yet changed by it walking in is changed.
@areaTrigger("at_wondervolt")
struct Wondervolt
{
    enum uint spellWondervoltTrap = 26275;
    static immutable uint[4] transformations = [26272, 26157, 26273, 26274];

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        foreach (spell; transformations)
            if (at.hasAura(e.player, spell))
                return;
        at.castSpell(e.player, spellWondervoltTrap, e.player);
        at.consume();
    }
}

/// The Wondervolt's trap (cast at who walks in): it changes into one of its four shapes.
@spell("spell_wondervolt_trap")
struct WondervoltTrap
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect == 0 && e.target)
            it.castSpell(e.target, Wondervolt.transformations[it.random(4)], e.target);
    }
}

/// The top of the Hive'Ashi tower in Silithus (Hive in the Tower): three drones come, for five minutes.
@areaTrigger("at_hive_tower")
struct HiveTower
{
    enum uint npcHiveAshiDrone = 13136;
    private static immutable Location[3] droneSpawns = [Location(-7185.94f, 443.29f, 26.59f, 4.8458f),
        Location(-7180.59f, 441.33f, 26.68f, 4.1798f), Location(-7176.63f, 437.42f, 26.84f, 3.9348f)];

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        // The drones of the last call still there: not again before their five minutes are over.
        foreach (spawn; droneSpawns)
            if (at.creatureNear(npcHiveAshiDrone, spawn, 8))
                return;
        foreach (spawn; droneSpawns)
            at.summon(npcHiveAshiDrone, spawn, 5 * 60_000);
        at.consume();
    }
}

/// Stormwind's recruiter, Justine Demalier, calls to an Alliance player who has not done The First and the Last.
@areaTrigger("at_stormwind_recruiter")
struct StormwindRecruiter
{
    enum : uint { npcJustineDemalier = 12481, questFirstAndLast = 6182, aiEventCustomA = 5 }

    void on(ref AreaTriggerContext at, const ref TriggerEntered e)
    {
        if (at.questStatus(e.player, questFirstAndLast) == QuestProgress.rewarded)
            return;
        if (const justine = at.creatureNear(npcJustineDemalier, e.at, 20))
            at.aiEvent(justine, aiEventCustomA, e.player);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;

    alias self = dmangos.scripts.worldobjects;

    // A bell tolls three at three o'clock, three seconds apart.
    assert(Bells.soundOf(Bells.hordeBell, Bells.areaUndercity) == Bells.tollTribal);
    assert(Bells.soundOf(Bells.allianceBell, Bells.areaDarnassus) == Bells.tollNightElf);
    auto bell = DrivenObject!self("go_bells", Bells.allianceBell);
    bell.host.minute = 2 * 60 + 59;
    bell.raise(Spawned());
    bell.run(30_000);
    assert(!bell.host.has("sound 6594"));
    bell.host.minute = 3 * 60;
    bell.run(36_000);
    size_t tolls;
    foreach (d; bell.host.did)
        tolls += d == "sound 6594";
    assert(tolls == 3);

    // The wagon calls the Venture Co. and sends them back.
    auto wagon = DrivenObject!self("go_covert_ops", 19_590);
    wagon.host.nearby[3989] = creatureRef(3989);
    wagon.raise(TrapSprung(hero));
    wagon.run(2000);
    assert(wagon.host.has("move 3989"));
    wagon.run(45_000);
    assert(wagon.host.has("home 3989") && !wagon.busy);

    // The transpolyporter carries only those with a transponder.
    auto porter = DrivenObject!self("go_transpolyporter_bb", 142_172);
    assert(porter.raise(TrapSprung(hero)));
    porter.host.items[9173] = true;
    assert(!porter.raise(TrapSprung(hero)));

    // A rift sends an invader while fewer than three are near.
    auto rift = DrivenObject!self("go_elemental_rift", 179_666);
    rift.raise(Spawned());
    rift.run(30_000);
    assert(rift.host.has("summon 14460"));
}
