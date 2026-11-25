/**
 * The raids' scripts on the real data: each boss spawned where the world database spawns it (or summoned where its
 * encounter summons it), fought by characters of level 60 made god-like, its stages driven by its health, and what a
 * player would see asserted: the spells it casts (by its own AI, the creature path), its lines (`script_texts`), the
 * creatures it calls, the copy's state of its encounter (in progress, done, and failed or not started again after a
 * wipe), and what its death does.
 *
 * What a boss must do comes from the data first (its spells' and texts' rows, its creature's), then the encounter as
 * the community's records describe it (Wowpedia, warcraft.wiki.gg), then the script's own documentation; CMaNGOS's
 * ScriptDev only as a second opinion. Where they disagree it is said at the boss.
 *
 * Runs only with the real data (`DMANGOS_REAL_DATA`).
 */
module dmangos.world.realscripts_raids;

version (unittest):

import core.time : msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import std.functional : toDelegate;
import dmangos.world.creature : Creature;
import dmangos.world.movement : Position;
import dmangos.world.realscriptkit_raids;
import dmangos.world.realspelltests : haveRealData;
import dmangos.world.updatefields;

/// Molten Core trash uses the database timer and tracks the linked boss across cells.
unittest
{
    import dmangos.world.grid : cellKeyAt;

    if (!haveRealData())
        return;
    enum uint moltenCore = 409, garrEntry = 12057, surgerEntry = 12101;
    const at = spawnOf(moltenCore, surgerEntry);
    auto s = new Scene(moltenCore, at);
    auto context = s.w.context;
    auto surger = s.the(surgerEntry);
    const guid = surger.guid, spawn = surger.spawn.guid;
    auto killAndRecord(Creature creature)
    {
        s.kill(creature);
        s.run(200.msecs);
        assert(context.deadInInstance(s.instance, creature.spawn.guid));
        return creature.respawnAt;
    }
    const due = killAndRecord(surger);
    const saved = s.w.db.loadInstances().respawns;
    assert(saved.canFind!(row => !row.gameObject && row.instance == s.instance && row.spawnGuid == spawn && row.until == due));
    s.w.now += (due - context.unixTime() - 1).seconds;
    context.respawnDue(s.w.now);
    assert(context.deadInInstance(s.instance, spawn));
    s.w.now += 1.seconds;
    context.respawnDue(s.w.now);
    auto back = s.map.creatureAt(guid);
    assert(back !is null && back !is surger && back.alive && !context.deadInInstance(s.instance, spawn));

    s.moveHero(0, spawnOf(moltenCore, garrEntry));
    auto garr = s.the(garrEntry);
    killAndRecord(garr);
    s.moveHero(0, at);
    const blocked = killAndRecord(back);
    s.w.now += (blocked - context.unixTime()).seconds;
    context.respawnDue(s.w.now);
    assert(context.deadInInstance(s.instance, spawn) && context.deadInInstance(s.instance, garr.spawn.guid));
    auto dead = s.map.creatureAt(guid);
    assert(dead is null || !dead.alive);

    // On a fresh load, a different, previously untouched Surger cannot spawn once Garr is dead either.
    foreach (const ref candidate; realData.creatureSpawns)
        if (candidate.entry == surgerEntry && candidate.map == moltenCore && candidate.guid != spawn)
        {
            const itsCell = cellKeyAt(candidate.x, candidate.y), killedCell = cellKeyAt(at.x, at.y);
            if (itsCell == killedCell || s.map.cellLoaded(itsCell))
                continue;
            s.map.loadCell(itsCell);
            assert(!s.all(surgerEntry).canFind!(c => c.spawn.guid == candidate.guid));
            return;
        }
    assert(false, "the fixture needs an unloaded Lava Surger cell");
}

/// One stage of a fight: the boss hurt to a share of its health, then the fight goes on; what it must have done.
struct Stage
{
    double hurtTo = 0;      /// the boss hurt to this percent first (0: not hurt)
    uint seconds;           /// then the fight goes on this long
    uint[] spells;          /// each cast by the boss (its own AI) by the stage's end
    int[] texts;            /// each line of `script_texts` said, yelled or emoted
    uint[2][] summons;      /// [entry, at least]: alive on the map at the stage's end
    uint[2][] addSpells;    /// [entry, spell]: cast by a creature of that entry
    void delegate(Scene, Creature) act; /// done before the stage runs (an add killed, ...)
}

/// A boss: where, which encounter, what its fight must show.
struct Boss
{
    string name;
    uint map, entry;
    int encounter = -1;       /// the copy's encounter (`TYPE_*`): asked, and in its saved state
    uint[] keep;              /// the creatures of the encounter, left when the trash round it is cleared
    Stage[] stages;
    int aggroText, deathText; /// 0: none
    ubyte resetTo = 2;        /// the encounter's state after a wipe (`failed`; some go back to `notStarted`)
    Position summonAt;        /// where it is summoned, if no spawn of it is in the data (x = 0: its spawn)
    ubyte[] classes = [classWarrior, classMage]; /// a fighter, and one with mana
    void delegate(Scene, Creature) afterDeath; /// what its death must have done
    float stayWithin = 10;    /// how far the characters let it get before they come back to it (a flyer: farther)
    bool despawnsOnWipe;      /// a wipe sends it away (one a gong or a ritual calls)
    void delegate(Scene, Creature) before; /// done before the fight (an event that calls it, ...)
    Position heroAt;          /// where the characters stand at first (x = 0: three yards from it)
    Creature delegate(Scene) arrive; /// how it comes (a gong struck, a ritual): it, come; null: spawned or summoned
}

/// Where the world database spawns `entry` on `map` (the first spawn).
Position spawnOf(uint map, uint entry)
{
    foreach (const ref s; realData.creatureSpawns)
        if (s.entry == entry && s.map == map)
            return Position(s.x, s.y, s.z, s.orientation);
    return Position.init;
}

/// The world data the real-data tests run on.
const(imported!"dmangos.world.worlddata".WorldData) realData()
{
    import dmangos.world.realspelltests : RealWorld;

    static imported!"std.typecons".Rebindable!(const(imported!"dmangos.world.worlddata".WorldData)) cached;
    if (cached is null)
        cached = RealWorld.make().context.data;
    return cached;
}

/// The scene for `b`: the characters three yards from it, the trash round it cleared; the boss.
Creature setUp(const ref Boss b, out Scene s)
{
    Position at = b.summonAt.x != 0 ? b.summonAt : b.heroAt.x != 0 ? b.heroAt : spawnOf(b.map, b.entry);
    assert(at.x != 0 || at.y != 0, format!"%s: no spawn of %s on map %s"(b.name, b.entry, b.map));
    Position heroAt = b.heroAt.x != 0 ? b.heroAt : at;
    if (b.heroAt.x == 0)
        heroAt.x += 3;
    s = new Scene(b.map, heroAt, b.classes);
    s.run(400.msecs); // its cells loaded (a boss may see them come: what it does then is seen too)
    auto boss = b.arrive !is null ? b.arrive(s) : b.summonAt.x != 0 ? s.summon(b.entry, at) : s.find(b.entry);
    assert(boss !is null, format!"%s: not on the map"(b.name));
    s.clear(boss.position, 80, b.keep ~ b.entry);
    s.stayWith = boss;
    s.stayWithin = b.stayWithin;
    if (b.before !is null)
        b.before(s, boss);
    return boss;
}

/// `b` fought to its death, each stage asserted.
void fight(const Boss b)
{
    Scene s;
    auto boss = setUp(b, s);
    const savedBefore = s.savedData();
    s.engage(boss);
    s.run(1.seconds);
    if (b.encounter >= 0)
        assert(s.ask(b.encounter) == 1, format!"%s: its encounter not in progress (%s)"(b.name, s.ask(b.encounter)));
    if (b.aggroText)
        assert(s.said(b.aggroText), format!"%s: no aggro line\n%s"(b.name, s.seen()));
    foreach (k, st; b.stages)
    {
        if (st.hurtTo > 0)
            s.hurtTo(boss, st.hurtTo);
        if (st.act !is null)
            st.act(s, boss);
        s.run(st.seconds.seconds);
        assert(boss.alive, format!"%s: dead in stage %s"(b.name, k));
        foreach (spell; st.spells)
            assert(s.castBy(b.entry, spell), format!"%s, stage %s: %s not cast\n%s"(b.name, k, spell, s.seen()));
        foreach (pair; st.addSpells)
            assert(s.castBy(pair[0], pair[1]), format!"%s, stage %s: %s not cast by a %s\n%s"(b.name, k, pair[1],
                pair[0], s.seen()));
        foreach (t; st.texts)
            assert(s.said(t), format!"%s, stage %s: line %s not said\n%s"(b.name, k, t, s.seen()));
        foreach (pair; st.summons)
            assert(s.all(pair[0]).length >= pair[1], format!"%s, stage %s: %s of %s alive, %s wanted"(b.name, k,
                s.all(pair[0]).length, pair[0], pair[1]));
    }
    s.kill(boss);
    s.run(3.seconds);
    if (b.deathText)
        assert(s.said(b.deathText), format!"%s: no death line\n%s"(b.name, s.seen()));
    if (b.encounter >= 0)
    {
        assert(s.ask(b.encounter) == 3, format!"%s: its encounter not done (%s)"(b.name, s.ask(b.encounter)));
        assert(s.savedData() != savedBefore, format!"%s: the copy's state not saved"(b.name));
    }
    if (b.afterDeath !is null)
        b.afterDeath(s, boss);
    assert(s.deaths.length == 0, format!"%s: a god-like character died"(b.name));
    // The copy unloaded and loaded again: the encounter is still done, and a boss the world spawns stays dead.
    if (s.instance && b.encounter >= 0)
    {
        s.reload();
        assert(s.ask(b.encounter) == 3, format!"%s: its encounter %s after the copy's reload"(b.name,
            s.ask(b.encounter)));
        if (b.summonAt.x == 0 && b.arrive is null)
            assert(s.find(b.entry) is null, format!"%s: alive again after the copy's reload"(b.name));
    }
}

/// `b` fought, the characters killed: it goes home whole, and its encounter is open again.
void wipe(const Boss b)
{
    Scene s;
    auto boss = setUp(b, s);
    s.engage(boss);
    s.run(5.seconds);
    s.hurtTo(boss, 90);
    s.wipe(boss);
    if (b.despawnsOnWipe)
    {
        assert(s.runUntil(() => s.map.creatureAt(boss.guid) is null, 60.seconds), b.name ~ ": not gone after the wipe");
        if (b.encounter >= 0)
            assert(s.ask(b.encounter) == b.resetTo, format!"%s: its encounter %s after the wipe, not %s"(b.name,
                s.ask(b.encounter), b.resetTo));
        return;
    }
    const home = s.runUntil(() => !boss.ai.inCombat && !boss.ai.evading
        && s.healthOf(boss) >= 100, 60.seconds);
    assert(boss.alive && home, format!"%s: not home and whole after the wipe (%s%%, in combat %s)"(b.name,
        s.healthOf(boss), boss.ai.inCombat));
    if (b.encounter >= 0)
        assert(s.ask(b.encounter) == b.resetTo, format!"%s: its encounter %s after the wipe, not %s"(b.name,
            s.ask(b.encounter), b.resetTo));
}

/// Kills one living creature of `entry` (the nearest).
void delegate(Scene, Creature) killOne(uint entry)
{
    return (Scene s, Creature boss) { s.kill(s.the(entry)); };
}

/// Hurts the nearest creature of `entry` to `percent`.
void delegate(Scene, Creature) hurtOne(uint entry, double percent)
{
    return (Scene s, Creature boss) { s.hurtTo(s.the(entry), percent); };
}

// ---------------------------------------------------------------------------------------------------------------
// Molten Core (409)
// ---------------------------------------------------------------------------------------------------------------

/// The bosses before Majordomo: each one's abilities, its encounter in progress, done at its death, open after a wipe.
unittest
{
    if (!haveRealData())
        return;
    enum uint protector = 12119, firesworn = 12099, coreRager = 11672, priest = 11662, flamewaker = 11661;
    const Boss[] bosses = [
        // Lucifron: Impending Doom, Lucifron's Curse, Shadow Shock; his two Flamewaker Protectors.
        Boss("Lucifron", 409, 12118, 0, [protector], [Stage(0, 20, [19702, 19703, 19460])]),
        // Magmadar: Panic, one Lava Bomb per interval, and Frenzy at 30 s with its emote.
        Boss("Magmadar", 409, 11982, 1, [], [Stage(0, 35, [19408, 19451], [-1_000_001]),
            Stage(0, 0, null, null, null, null,
            (Scene s, Creature boss) {
                long[] bombs;
                foreach (cast_; s.casts)
                    if (!cast_.started && cast_.caster == boss.guid && (cast_.spell == 19411 || cast_.spell == 20474))
                        bombs ~= cast_.atMs;
                assert(bombs.length == 2 && bombs[1] - bombs[0] >= 12_000,
                    format!"Magmadar's bombs should share one timer, saw %s"(bombs));
            })], 0, 0, 0),
        // Gehennas: his curse, Rain of Fire, Shadow Bolt at random and at his victim; two Flamewakers.
        Boss("Gehennas", 409, 12259, 2, [flamewaker], [Stage(0, 15, [19716, 19717, 19729, 19728])]),
        // Garr: Antimagic Pulse, Magma Shackles; a Firesworn killed erupts and enrages him; Massive Eruption.
        Boss("Garr", 409, 12057, 3, [firesworn], [Stage(0, 18, [19492, 19496]),
            Stage(0, 2, [19516], null, null, [[firesworn, 19497]], killOne(firesworn)),
            // after six minutes a Firesworn made to erupt every 20 s (his emote)
            Stage(0, 345, null, [-1_409_025], null, [[firesworn, 20483]])]),
        // Shazzrah: Arcane Explosion, his curse, Counterspell, Magic Grounding (24 s), the Gate (30 s).
        Boss("Shazzrah", 409, 12264, 4, [], [Stage(0, 33, [19712, 19713, 19715, 19714, 23138])], 0, 0, 0),
        // Baron Geddon: Ignite Mana (30 s), Living Bomb (35 s), Inferno (45 s); Armageddon at 2% with his emote.
        Boss("Baron Geddon", 409, 12056, 5, [], [Stage(0, 47, [19659, 20475, 19695]),
            Stage(2, 2, [20478], [-1_409_000])], 0, 0, 0),
        // Golemagg: Pyroblast; Earthquake under 10%. A Core Rager at half health heals fully (its emote); the
        // ragers die with him.
        Boss("Golemagg", 409, 11988, 6, [coreRager], [Stage(0, 9, [20228]),
            Stage(0, 2, null, [-1_409_002], null, [[coreRager, 17683]], hurtOne(coreRager, 40)),
            Stage(9, 4, [19798])], 0, 0, 2, Position.init, [classWarrior, classMage],
            (Scene s, Creature boss) { assert(s.all(coreRager).length == 0, "Golemagg's Core Ragers live on"); }),
        // Sulfuron: Flame Spear, Inspire, Hand of Ragnaros, Demoralizing Shout; his priests' Shadow Word: Pain,
        // Immolate and Dark Strike.
        Boss("Sulfuron Harbinger", 409, 12098, 7, [priest], [Stage(0, 16, [19781, 19779, 19780, 19778], null, null,
            [[priest, 19776], [priest, 20294], [priest, 19777]])]),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

/// A landed Lava Bomb puts Conflagration at the impact point.
unittest
{
    import dmangos.script.api : ActionResult;

    if (!haveRealData())
        return;
    enum uint magmadarEntry = 11982, lavaBomb = 19411, firePatch = 177704, conflagration = 19428;
    if (realData.gameObjectScriptNames.get(firePatch, "") != "go_magmadar_lava_bomb")
        return; // The stock-database fix supplies the trap script binding.
    const spawn = spawnOf(409, magmadarEntry);
    auto s = new Scene(409, Position(spawn.x + 24, spawn.y, spawn.z), [classWarrior, classMage]);
    auto magmadar = s.the(magmadarEntry);
    s.moveHero(1, Position(spawn.x + 40, spawn.y, spawn.z));
    assert(magmadar.ai.castFor(s.map, lavaBomb, s.hero.guid, true) == ActionResult.ok);
    const fires = s.objects(firePatch);
    assert(fires.length == 1 && Scene.distance(fires[0].position, s.hero.position) < 0.1f);
    s.godlike = false;
    s.fill();
    const health = s.heroUnit.health;
    s.run(3.seconds);
    assert(s.heroUnit.hasAuraOf(conflagration) && s.heroUnit.health < health);
    assert(!s.heroUnit(1).hasAuraOf(conflagration));
}

/// Where the world database spawns the game object `entry` on `map` (the first spawn).
Position objectSpawnOf(uint map, uint entry)
{
    foreach (const ref s; realData.gameObjectSpawns)
        if (s.entry == entry && s.map == map)
            return Position(s.x, s.y, s.z, s.orientation);
    return Position.init;
}

/**
 * The runes, Majordomo Executus and Ragnaros: a rune is doused only once its guard has fallen; every rune doused,
 * Majordomo comes with his eight guards (his line); he fights behind his shields, teleporting, and submits when the
 * last guard falls (his speech), the Cache of the Firelord appears, and he waits by Ragnaros' lair; asked, he summons
 * Ragnaros (the scene's lines) and is burnt; Ragnaros fights (Magma Blast, Might, Wrath, Lava Burst), submerges with
 * his eight Sons of Flame, comes up when they are dead, and dies. The copy's state survives its unloading.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint
    {
        kress = 176956, majordomoEntry = 12018, ragnarosEntry = 11502, healer = 11663, elite = 11664,
        sonOfFlame = 12143, cache = 179703, aqualQuintessence = 17333,
    }
    // At the Rune of Kress, Magmadar alive: it is not doused.
    auto runeAt = objectSpawnOf(409, kress);
    auto s = new Scene(409, Position(runeAt.x + 2, runeAt.y, runeAt.z), [classWarrior, classMage]);
    s.run(400.msecs);
    auto rune = s.objects(kress);
    assert(rune.length == 1, "no Rune of Kress");
    const refused = s.useItemOn(aqualQuintessence, rune[0]); // the rune is doused with the item (its spell, 21358)
    s.run(6.seconds);
    assert(s.ask(1) == 0, format!"Kress doused with Magmadar alive (%s)"(s.ask(1)));
    // Magmadar dead (his death tells the copy): now it is.
    s.kill(s.the(11982));
    s.run(1.seconds);
    assert(s.ask(1) == 3, "Magmadar's encounter not done");
    { const r = s.useItemOn(aqualQuintessence, rune[0]); assert(r == 0, format!"Aqual Quintessence not used on the rune: %s (before: %s)"(r, refused)); }
    s.run(6.seconds);
    assert(s.ask(1) == 4, format!"Kress not doused (%s)"(s.ask(1)));
    // The others' guards dead and their runes doused (as their scripts tell the copy), Lucifron dead.
    s.moveHeroes(Position(760, -1170, -118.6f));
    s.run(1.seconds);
    s.forget();
    s.signalCopy(0, 3);
    foreach (encounter; 2 .. 8)
    {
        s.signalCopy(encounter, 3);
        s.signalCopy(encounter, 4);
    }
    s.run(1.seconds);
    auto majordomo = s.the(majordomoEntry);
    assert(s.said(-1_409_004), "no line as the runes are doused\n" ~ s.seen());
    assert(s.all(healer).length == 4 && s.all(elite).length == 4, format!"Majordomo's guard: %s healers, %s elites"(
        s.all(healer).length, s.all(elite).length));
    // The state survives the copy's unloading: Majordomo comes again (with his guard) as a player enters.
    s.reload();
    foreach (encounter; 1 .. 8)
        assert(s.ask(encounter) == 4, format!"encounter %s not doused after the reload (%s)"(encounter, s.ask(encounter)));
    assert(s.ask(0) == 3, "Lucifron not done after the reload");
    majordomo = s.the(majordomoEntry);
    assert(s.all(healer).length == 4 && s.all(elite).length == 4, "Majordomo's guard not back after the reload");

    // His fight.
    s.stayWith = majordomo;
    s.forget();
    s.engage(majordomo);
    s.run(31.seconds);
    assert(s.said(-1_409_003), "no aggro line\n" ~ s.seen());
    assert(s.ask(8) == 1, "his encounter not in progress");
    foreach (spell; [20620, 20534, 20618])
        assert(s.castBy(majordomoEntry, spell), format!"Majordomo: %s not cast\n%s"(spell, s.seen()));
    assert(s.castBy(majordomoEntry, 20619) || s.castBy(majordomoEntry, 21075), "Majordomo: no reflection\n" ~ s.seen());
    // His guard falls: at the last one, his line; at none, he submits.
    foreach (k; 0 .. 7)
    {
        s.kill(s.all(k < 3 ? elite : healer)[0]);
        s.run(1.seconds);
    }
    assert(s.said(-1_409_019), "no line as one guard is left\n" ~ s.seen());
    assert(s.castBy(majordomoEntry, 21090), "no Champion on the last guard\n" ~ s.seen());
    s.kill(s.all(elite)[0]);
    assert(s.runUntil(() => s.said(-1_409_021), 40.seconds), "no surrender speech\n" ~ s.seen());
    assert(s.said(-1_409_007) && s.said(-1_409_020), "the surrender speech incomplete\n" ~ s.seen());
    assert(majordomo.alive, "Majordomo died");
    assert(s.ask(8) == 3, format!"his encounter not done (%s)"(s.ask(8)));
    assert(s.objects(cache).length == 1, "no Cache of the Firelord");
    s.run(25.seconds);
    assert(Scene.distance(majordomo.position, Position(848.933f, -812.875f, -229.601f)) < 5,
        format!"Majordomo not by Ragnaros' lair: %s"(majordomo.position));

    // Asked, he summons Ragnaros.
    s.stayWith = null;
    s.moveHeroes(Position(845, -815, -229.6f));
    s.run(1.seconds);
    s.forget();
    s.gossip(majordomo, [0, 0, 0]);
    assert(s.said(-1_409_023), "Majordomo does not answer\n" ~ s.seen());
    assert(s.runUntil(() => s.find(ragnarosEntry) !is null && !majordomo.alive, 90.seconds),
        "no Ragnaros, or Majordomo lives\n" ~ s.seen());
    foreach (line; [-1_409_024, -1_409_008, -1_409_009, -1_409_010, -1_409_011])
        assert(s.said(line), format!"the summoning: line %s not said\n%s"(line, s.seen()));
    assert(s.castBy(majordomoEntry, 19774), "no Summon Ragnaros\n" ~ s.seen());
    auto ragnaros = s.the(ragnarosEntry);
    s.stayWith = ragnaros;
    s.stayWithin = 6;
    assert(s.runUntil(() => ragnaros.ai.inCombat, 20.seconds), "Ragnaros does not fight\n" ~ s.seen());
    assert(s.said(-1_409_012), "no line as Ragnaros fights\n" ~ s.seen());
    assert(s.ask(9) == 1, "his encounter not in progress");
    s.forget();
    s.run(35.seconds);
    foreach (spell; [21154, 20566, 21908])
        assert(s.castBy(ragnarosEntry, spell), format!"Ragnaros: %s not cast\n%s"(spell, s.seen()));
    assert(s.said(-1_409_015) && s.said(-1_409_016), "no Might or Wrath line\n" ~ s.seen());
    // Three minutes in he submerges: eight Sons of Flame; they dead, he comes up.
    s.stayWith = null;
    assert(s.runUntil(() => s.said(-1_409_013), 160.seconds), "Ragnaros does not submerge\n" ~ s.seen());
    s.run(4.seconds);
    assert(s.all(sonOfFlame).length == 8, format!"%s Sons of Flame"(s.all(sonOfFlame).length));
    foreach (son; s.all(sonOfFlame))
        s.kill(son);
    s.forget();
    assert(s.runUntil(() => s.castBy(ragnarosEntry, 20568), 5.seconds), "Ragnaros does not come up\n" ~ s.seen());
    // His death.
    s.kill(ragnaros);
    s.run(2.seconds);
    assert(s.ask(9) == 3, "his encounter not done");
    assert(s.deaths.length == 0, "a god-like character died");
}

// ---------------------------------------------------------------------------------------------------------------
// Onyxia's Lair (249)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Onyxia: on the ground Flame Breath, Cleave, Tail Sweep, Wing Buffet and Knock Away; at 65% she says so and takes
 * off (the copy answers "lift off" while she is up): Fireball, whelps from the nests; at 40% she lands (her line) and
 * roars (Bellowing Roar). Wowpedia: phase 2 at 65%, phase 3 at 40%, the whelps and the deep breaths.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint whelp = 11262;
    auto airborne = (Scene s, Creature boss) {
        assert(s.ask(0) == 4, format!"Onyxia up, but the copy says %s"(s.ask(0)));
    };
    const onyxia = Boss("Onyxia", 249, 10184, 0, [12758], [
        Stage(0, 32, [18435, 19983, 15847, 18500, 19633]),
        Stage(64, 30, [18392], [-1_249_002], [[whelp, 2]]),
        Stage(0, 1, null, null, null, null, toDelegate(airborne)),
        // in the air every 25 s a deep breath across the lair (its emote) or a flight to the next spot
        Stage(0, 100, null, [-1_249_004]),
        Stage(39, 20, [18431], [-1_249_003]),
    ], -1_249_000, 0, 2, Position.init, [classWarrior, classMage], null, 80);
    fight(onyxia);
    wipe(onyxia);
}

// ---------------------------------------------------------------------------------------------------------------
// Zul'Gurub (309)
// ---------------------------------------------------------------------------------------------------------------

/**
 * The high priests, Mandokir, Hakkar, Renataki: their phases change their `creature_spell_list`s (whose spells, cast
 * by the list at their timers, are what the stages ask for), their lines, what they call.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint { batRider = 14750, chainedSpirit = 15117, ohgan = 14988, hakkarsPower = 24692 }
    const Boss[] bosses = [
        // Venoxis (list 1450701): Holy Fire, Holy Nova, Thrash, Holy Wrath; at 50% the snake (23849, his line,
        // Poison Cloud; list 1450702: Venom Spit); under 25% list 1450703 (Parasitic Serpent); under 20% Frenzy.
        Boss("Venoxis", 309, 14507, 1, [], [
            Stage(0, 50, [23860, 23858, 3391, 23979]),
            Stage(49, 8, [23849, 23861, 23862], [-1_309_000]),
            Stage(24, 4, [23867]),
            Stage(19, 2, [23537])], 0, -1_309_001),
        // Jeklik: her bat form at the pull (23966); list 1451701 (Sonic Burst, Pierce Armor, Charge, Blood Leech,
        // the bats); at 50% she lands (24085; list 1451702: Shadow Word: Pain, Mind Flay, Great Heal); at 35% two
        // Gurubashi Bat Riders and her line.
        Boss("Jeklik", 309, 14517, 0, [], [
            Stage(0, 52, [23966, 23918, 12097, 22644, 23974]), // Charge (22911): at someone 8 yards off or more
            Stage(49, 22, [24085, 23952, 23953, 23954]),
            Stage(34, 2, null, [-1_309_003], [[batRider, 2]])], -1_309_002, -1_309_004),
        // Mar'li: Hatch Spider Eggs at the pull; list 1451001 (Poison Bolt Volley, Drain Life, Thrash); at a minute
        // the spider (24084, her line; list 1451002: Corrosive Poison, Enveloping Webs, Poison Shock); at two, back.
        Boss("Mar'li", 309, 14510, 2, [], [
            Stage(0, 35, [24083, 24099, 24300, 3391]),
            Stage(0, 36, [24084, 24111, 24110, 24112], [-1_309_006]),
            Stage(0, 50, [24085], [-1_309_025])], -1_309_005, -1_309_008),
        // Mandokir: his line, the nineteen chained spirits and Ohgan at the pull; list 1138201 (Mortal Strike,
        // Overpower, Intimidating Shout, Whirlwind, Charge, Threatening Gaze and his line at the gazed); Ohgan
        // slain, he rages (23537, the emote).
        Boss("Mandokir", 309, 11382, 5, [chainedSpirit, ohgan], [
            Stage(0, 46, [16856, 24407, 19134, 24408, 24314], [-1_309_018], [[chainedSpirit, 19], [ohgan, 1]]),
            Stage(0, 25, [13736], null, null, null, (Scene s, Creature boss) {
                // After testing the ranged charge, keep the target in melee for Whirlwind.
                s.stayWithin = 2;
                foreach (i; 0 .. s.heroes.length)
                    s.moveHero(i, boss.position);
            }),
            Stage(0, 3, [23537], [-1_309_024], null, null, killOne(ohgan))], -1_309_015, 0, 2, Position.init,
            [classWarrior, classMage], null, 10, false, null, Position(-12190, -1948, 130.3f), (Scene s) {
                // He comes down from his perch when the copy says (its keepers slain), and fights all there.
                auto him = s.the(11382);
                s.signalCopy(5, 4);
                assert(s.runUntil(() => him.ai.inCombat, 60.seconds), "Mandokir does not come down to fight");
                return him;
            }),
        // Hakkar gets a stack of Power and the matching Aspect from each living priest.
        // His spell list also includes Cause Insanity, Will of Hakkar, Corrupted Blood and Blood Siphon.
        Boss("Hakkar", 309, 14834, -1, [], [
            Stage(0, 2, null, null, null, null, (Scene s, Creature boss) {
                const aura = boss.auras.find(hakkarsPower);
                assert(aura !is null && aura.stacks == 5, format!"Hakkar's Power: %s stacks, not 5"(
                    aura is null ? 0 : aura.stacks));
            }),
            Stage(0, 90, [24327, 24178, 24328, 24324, 24687]),
            Stage(0, 1, null, null, null, null, (Scene s, Creature boss) {
                import dmangos.world.grid : cellKeyAt;

                // Jeklik's native death both weakens Hakkar and closes her Aspect's expression gate.
                foreach (ref spawn; s.w.context.data.creatureSpawns)
                    if (spawn.map == 309 && spawn.entry == 14517)
                    {
                        s.map.loadCell(cellKeyAt(spawn.x, spawn.y));
                        break;
                    }
                s.kill(s.the(14517));
                assert(!s.w.context.worldStateExpressionMet(s.map, 2984));
            }),
            Stage(0, 1, null, null, null, null, (Scene s, Creature boss) {
                const aura = boss.auras.find(hakkarsPower);
                assert(aura !is null && aura.stacks == 4, format!"Hakkar's Power: %s stacks, a priest slain"(
                    aura is null ? 0 : aura.stacks));
            })], -1_309_020),
        // Renataki (summoned by the Edge of Madness): list 1508401 (Thousand Blades, Gouge, Thrash, Vanish).
        Boss("Renataki", 309, 15084, -1, [], [Stage(0, 32, [24649, 24698, 3391, 24699])], 0, 0, 2,
            Position(-11560, -1627, 41.3f)),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Blackwing Lair (469)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Broodlord Lashlayer, the three drakes and Chromaggus: each one's abilities by its timers, its encounter. Chromaggus
 * breathes the two breaths the copy drew for him (its answers 9 and 10), shimmers, frenzies, and enrages under 20%.
 */
unittest
{
    if (!haveRealData())
        return;
    auto breaths = (Scene s, Creature boss) {
        foreach (side; [9, 10])
        {
            const breath = cast(uint) s.ask(side);
            assert(breath, format!"the copy drew no breath for side %s"(side));
            assert(s.castBy(14020, breath), format!"Chromaggus: breath %s not breathed\n%s"(breath, s.seen()));
        }
    };
    const Boss[] bosses = [
        // Broodlord: his line; Cleave (8 s), Knock Away (12 s), Blast Wave (20 s), Mortal Strike (30 s).
        Boss("Broodlord Lashlayer", 469, 12017, 2, [], [Stage(0, 32, [15284, 18670, 23331, 24573])], -1_469_000),
        // The drakes: their own (Firemaw's Flame Buffet, Ebonroc's Shadow of Ebonroc at 45 s, Flamegor's Frenzy
        // and its emote), Shadow Flame (18 s), Wing Buffet (30 s), Thrash.
        Boss("Firemaw", 469, 11983, 3, [], [Stage(0, 32, [23341, 22539, 23339, 3391])]),
        Boss("Ebonroc", 469, 14601, 4, [], [Stage(0, 47, [23340, 22539, 23339, 3391])]),
        Boss("Flamegor", 469, 11981, 5, [], [Stage(0, 32, [23342, 22539, 23339, 3391], [-1_000_002])]),
        Boss("Chromaggus", 469, 14020, 6, [], [
            Stage(0, 62, [22276, 23173, 23128], [-1_469_003, -1_000_001]),
            Stage(0, 1, null, null, null, null, toDelegate(breaths)),
            Stage(19, 2, [23537], [-1_000_002])]),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

/**
 * Razorgore's room: Grethok attacked, the room wakes (the encounter in progress, the main gate shut) and the
 * generators send their defenders; every egg broken, the orb goes dark (the emotes), the defenders flee, Razorgore
 * is freed whole and fights (Cleave, Conflagration, Fireball Volley, War Stomp); his death opens the way on.
 * Brought down while an egg is whole, he does not die: the room fails (his line).
 * Players alternate at the Orb of Domination and order the possessed dragon to destroy the eggs.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint
    {
        grethok = 12557, razorgoreEntry = 12435, egg = 177807, legionnaire = 12416, mage = 12420, dragonspawn = 12422,
        gateIn = 176964, gateOut = 176965,
    }
    auto s = new Scene(469, Position(-7612, -1024, 413), [classWarrior, classMage, classPriest]);
    s.run(1.seconds);
    auto razorgore = s.the(razorgoreEntry);
    assert(s.doorOpen(gateIn) && !s.doorOpen(gateOut), "the gates before the fight");
    s.engage(s.the(grethok));
    s.run(1.seconds);
    assert(s.ask(0) == 1, "Grethok attacked: the room not awake");
    assert(!s.doorOpen(gateIn), "the main gate open during the fight");
    // (Another copy: the defenders sent after 40 s; Razorgore brought down with his eggs whole does not die, the
    // room fails.)
    auto t = new Scene(469, Position(-7570, -1085, 413), [classWarrior]);
    t.run(1.seconds);
    auto other = t.the(grethok);
    t.engage(other);
    t.run(41.seconds);
    assert(t.all(legionnaire).length + t.all(mage).length + t.all(dragonspawn).length > 0, "no defenders sent");
    auto hisTwin = t.the(razorgoreEntry);
    t.kill(hisTwin);
    t.run(2.seconds);
    assert(hisTwin.alive, "Razorgore died with his eggs whole");
    assert(t.ask(0) == 2 && t.said(-1_469_025), format!"the room did not fail (%s)\n%s"(t.ask(0), t.seen()));

    // Grethok and his guards slain (as the raid does first), every egg broken.
    s.kill(s.the(grethok));
    foreach (guard; s.all(14456))
        s.kill(guard);
    s.run(1.seconds);
    s.moveHero(2, Position(-7643, -1080, 409)); // an observer by Nefarian's troops (their emotes are heard 25 yards off)
    s.forget();
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGuid;
    auto orb = s.objects(177808)[0];
    auto eggs = s.objects(egg);
    const eggCount = eggs.length;
    s.moveHero(0, eggs[0].position);
    s.use(eggs[0]);
    s.run(400.msecs);
    assert(s.map.findObject(eggs[0].guid) is eggs[0], "a player cannot break an egg by clicking it");
    size_t controller;
    foreach (e; eggs)
    {
        for (size_t attempt; s.map.findObject(e.guid) !is null && attempt < 3; ++attempt)
        {
            if (s.heroes[controller].session.inWorld.charmed !is razorgore)
            {
                if (s.hero(controller).auras.find(23958) !is null)
                    controller = 1 - controller;
                s.moveHero(controller, orb.position);
                s.heroes[controller].write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(orb.guid));
                assert(s.heroes[controller].session.inWorld.charmed is razorgore,
                    format!"the orb did not grant possession, raid state %s"(s.ask(0)));
                assert(s.hero(controller).auras.find(23958) !is null && razorgore.petData.knows(19873));
            }
            const at = e.position;
            auto movement = razorgore.movement;
            movement.position = at;
            import dmangos.bytes : ByteWriter;
            ByteWriter move;
            movement.write(move);
            s.heroes[controller].write(Opcode.MSG_MOVE_HEARTBEAT, move.data);
            const lastEgg = s.objects(egg).length == 1;
            if (lastEgg)
                s.hurtTo(razorgore, 50);
            orderControlled(s, razorgore, 19873, razorgore.guid, controller);
            if (lastEgg)
                s.runUntil(() => s.ask(0) == 4, 10.seconds);
            else
                s.run(10.seconds);
        }
        assert(s.map.findObject(e.guid) is null,
            format!"Destroy Egg failed at %s, dragon %s, spell result %s, controller %s, remaining %s of %s; %s"(
                e.position, razorgore.position, razorgore.ai.castRefusal, controller, s.objects(egg).length, eggCount, s.seen()));
    }
    assert(s.ask(0) == 4, format!"the eggs broken, but the room is %s (%s eggs left of %s)"(s.ask(0), s.objects(egg).length, eggCount));
    assert(s.said(-1_469_035) && s.said(-1_469_033), "no emotes as the orb goes dark\n" ~ s.seen());
    assert(razorgore.petOwner == 0 && s.castBy(razorgoreEntry, 23040) && s.healthOf(razorgore) > 99,
        format!"Razorgore released %s, Warming Flames %s, health %s"(razorgore.petOwner == 0, s.castBy(razorgoreEntry, 23040), s.healthOf(razorgore)));
    // His fight.
    s.stayWith = razorgore;
    s.moveHeroes(razorgore.position);
    s.forget();
    s.engage(razorgore);
    s.run(31.seconds);
    foreach (spell; [19632, 23023, 22425, 24375])
        assert(s.castBy(razorgoreEntry, spell), format!"Razorgore: %s not cast\n%s"(spell, s.seen()));
    s.kill(razorgore);
    s.run(2.seconds);
    assert(!razorgore.alive && s.ask(0) == 3, "Razorgore's encounter not done");
    assert(s.doorOpen(gateOut) && s.doorOpen(gateIn), "the way on not open");
}

/**
 * Vaelastrasz: lying at 30%; players come near (the area trigger 3626), Nefarius comes and corrupts him (his two
 * lines, Red Lightning); spoken to, Vaelastrasz says his three lines and turns on them: Essence of the Red, Fire
 * Nova, Cleave, Flame Breath, Burning Adrenaline (at one with mana), Tail Sweep, Burning Adrenaline on his victim
 * (45 s); under 15% his line. Wowpedia: he starts at 30% health; Burning Adrenaline every 15 s on a mana user, every
 * 45 s on the tank.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint vaelEntry = 13020, nefarius = 10162;
    auto s = new Scene(469, Position(-7480, -1016, 408.6f), [classWarrior, classMage]);
    s.run(1.seconds);
    auto vael = s.the(vaelEntry);
    assert(s.healthOf(vael) <= 31, format!"Vaelastrasz at %s%%, not 30%%"(s.healthOf(vael)));
    s.enterTrigger(3626);
    s.run(20.seconds);
    assert(s.ask(1) == 4, format!"the trigger did not begin his scene (%s)"(s.ask(1)));
    assert(s.find(nefarius) !is null || s.all(nefarius, true).length, "no Nefarius at the throne");
    assert(s.said(-1_469_006) && s.said(-1_469_032), "Nefarius' lines\n" ~ s.seen());
    assert(s.cast_(23642) && s.cast_(19484), "no corruption or Red Lightning\n" ~ s.seen());
    s.stayWith = vael;
    s.moveHeroes(vael.position);
    s.run(400.msecs);
    s.gossip(vael, [0, 0]);
    s.run(1.seconds);
    assert(s.said(-1_469_026), "Vaelastrasz does not answer\n" ~ s.seen());
    assert(s.runUntil(() => vael.ai.inCombat, 40.seconds), "Vaelastrasz does not turn on them\n" ~ s.seen());
    assert(s.said(-1_469_027) && s.said(-1_469_028), "his speech\n" ~ s.seen());
    assert(s.ask(1) == 1, "his encounter not in progress");
    s.run(1.seconds);
    assert(s.castBy(vaelEntry, 23513), "no Essence of the Red as he turns\n" ~ s.seen());
    s.forget();
    s.run(46.seconds);
    foreach (spell; [23462, 19983, 23461, 23620, 15847, 18173])
        assert(s.castBy(vaelEntry, spell), format!"Vaelastrasz: %s not cast\n%s"(spell, s.seen()));
    s.hurtTo(vael, 14);
    s.run(1.seconds);
    assert(s.said(-1_469_029), "no line under 15%");
    s.kill(vael);
    s.run(2.seconds);
    assert(s.ask(1) == 3 && s.doorOpen(179364), "his encounter not done, or his door shut");
}

/**
 * Nefarius and Nefarian: spoken to, Nefarius begins the games (his two lines) and fights from his hall (Shadow Bolt,
 * Fear, Shadow Bolt Volley, Silence, Shadow Command, Shadowblink) while drakonids pour from the tunnels; forty-two
 * slain, Nefarian comes (his lines as he flies in), lands and fights: Cleave, Tail Lash, Shadow Flame, Veil of
 * Shadow, Bellowing Roar, his class calls (the warrior's and the mage's, with their lines); under 20% the
 * drakonids' bones rise (his line), under 5% his line; his death.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint nefariusEntry = 10162, nefarianEntry = 11583;
    static immutable uint[6] drakonids = [14261, 14262, 14263, 14264, 14265, 14302];
    auto s = new Scene(469, Position(-7585, -1262, 481.6f), [classWarrior, classMage]);
    s.run(1.seconds);
    auto nefarius = s.the(nefariusEntry);
    s.gossip(nefarius, [0, 0, 0]);
    assert(s.runUntil(() => nefarius.ai.inCombat, 15.seconds), "Nefarius does not begin\n" ~ s.seen());
    assert(s.said(-1_469_004) && s.said(-1_469_005), "his lines\n" ~ s.seen());
    assert(s.ask(7) == 1, "the encounter not in progress");
    s.stayWith = nefarius;
    s.run(41.seconds);
    foreach (spell; [22677, 22678, 22665, 22666, 22667, 22664])
        assert(s.castBy(nefariusEntry, spell), format!"Nefarius: %s not cast\n%s"(spell, s.seen()));
    // The tunnels' spawners: each one's Spawn Drakonid (22659, the tick of its Drakonid Spawner) calls a drakonid of
    // its colour. (The tick itself is not cast: a creature's periodic trigger auras do nothing yet, see the report;
    // the spawners' EventAI sends a chromatic one a minute. So the test casts the tick, and summons the rest.)
    {
        import dmangos.world.eventai : castTriggered;

        static immutable uint[2][5] colours = [[14307, 14265], [14309, 14264], [14310, 14262], [14311, 14263],
            [14312, 14261]];
        foreach (c; colours)
        {
            auto spawner = s.find(c[0]);
            if (spawner is null)
                continue;
            const before = s.all(c[1]).length;
            assert(spawner.ai.scriptCast(22659, spawner.guid, castTriggered), "Spawn Drakonid not cast");
            s.run(400.msecs);
            assert(s.all(c[1]).length == before + 1, format!"spawner %s called no drakonid %s"(c[0], c[1]));
        }
    }
    // Forty-two drakonids slain (those the tunnels send, and as many more as they would have).
    s.stayWith = null;
    s.forget();
    size_t slain;
    const enough = s.runUntil(() {
        foreach (entry; drakonids)
            foreach (d; s.all(entry))
            {
                s.kill(d);
                ++slain;
            }
        if (s.ask(7) == 1)
            s.summon(drakonids[slain % 5], Position(-7599.32f, -1191.72f, 475.545f));
        return s.ask(7) == 4;
    }, 120.seconds, 1.seconds);
    assert(enough, format!"%s drakonids slain, no Nefarian"(slain));
    assert(slain >= 42, format!"Nefarian comes after %s drakonids"(slain));
    assert(s.runUntil(() => s.find(nefarianEntry) !is null, 10.seconds), "no Nefarian");
    auto nefarian = s.the(nefarianEntry);
    assert(s.runUntil(() => nefarian.ai.inCombat, 60.seconds), "Nefarian does not land to fight\n" ~ s.seen());
    // (His first line, -1469007, he yells where he appears: 330 yards from the hall, beyond a yell's 300.)
    assert(s.said(-1_469_009), "his line as he comes\n" ~ s.seen());
    s.stayWith = nefarian;
    s.run(36.seconds);
    foreach (spell; [19983, 23364, 22539, 22687, 22686])
        assert(s.castBy(nefarianEntry, spell), format!"Nefarian: %s not cast\n%s"(spell, s.seen()));
    assert((s.castBy(nefarianEntry, 23397) && s.said(-1_469_014)) || (s.castBy(nefarianEntry, 23410)
        && s.said(-1_469_013)), "no class call\n" ~ s.seen());
    s.hurtTo(nefarian, 19);
    s.run(5.seconds);
    assert(s.castBy(nefarianEntry, 23362) && s.said(-1_469_010), format!"the bones do not rise (%s%%)\n%s"(s.healthOf(nefarian), s.seen()));
    s.hurtTo(nefarian, 4);
    s.run(1.seconds);
    assert(s.said(-1_469_008), "no line under 5%");
    s.kill(nefarian);
    s.run(2.seconds);
    assert(s.said(-1_469_012) && s.ask(7) == 3, "his death");
}

// ---------------------------------------------------------------------------------------------------------------
// Ruins of Ahn'Qiraj (509)
// ---------------------------------------------------------------------------------------------------------------

/// Whether `boss` has an aura of `spell`.
bool hasAura(Creature boss, uint spell)
{
    return boss.auras.find(spell) !is null;
}

/**
 * Kurinnaxx, Moam, Buru, Ayamiss, Ossirian: each one's abilities; the copy's encounter in progress as it fights,
 * done at its death, failed after a wipe (ScriptDev's `OnCreatureEvade`). Kurinnaxx's death brings General Andorov
 * and his four Kaldorei Elites, and Ossirian's line. Moam turns to stone at 90 s (three Mana Fiends, Energize and its
 * emote) and wakes when they are slain. Buru takes his prey (his emote), and under 20% transforms (Creeping Plague)
 * and his eggs hatch. Ayamiss flies (Stinger, Paralyze and a larva at the altar, swarmers), lands at 70% (Lash) and
 * frenzies under 20%. Ossirian is supreme until a crystal is used by him (one of the five weaknesses).
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint
    {
        andorov = 15471, kaldorei = 15473, manaFiend = 15527, buruEgg = 15514, hatchling = 15521, larva = 15555,
        swarmer = 15546, sandVortex = 15428, crystal = 180619, ossirianEntry = 15339, energize = 25685, supreme = 25176,
    }
    static immutable uint[5] weaknesses = [25177, 25178, 25180, 25181, 25183];
    auto stone = (Scene s, Creature moam) {
        assert(hasAura(moam, energize), "Moam not turned to stone");
        foreach (f; s.all(manaFiend))
            s.kill(f);
    };
    auto awake = (Scene s, Creature moam) { assert(!hasAura(moam, energize), "Moam still stone, his fiends slain"); };
    auto useCrystal = (Scene s, Creature ossirian) {
        auto crystals = s.objects(crystal);
        assert(crystals.length, "no Ossirian Crystal");
        // The raid takes him to the crystal (its weakness strikes only within reach of where it stands).
        s.stayWith = null;
        s.moveHeroes(crystals[0].position);
        assert(s.runUntil(() => Scene.distance(ossirian.position, crystals[0].position) < 15, 30.seconds),
            format!"Ossirian does not follow to the crystal at %s: at %s, %s crystals"(crystals[0].position, ossirian.position, crystals.length));
        s.use(crystals[0]);
    };
    auto weakened = (Scene s, Creature ossirian) {
        bool weak;
        foreach (w; weaknesses)
            weak |= hasAura(ossirian, w);
        assert(weak && !hasAura(ossirian, supreme), "Ossirian not weakened by the crystal\n" ~ s.seen());
    };
    const Boss[] bosses = [
        // Kurinnaxx: Thrash, Sand Trap, Mortal Wound, Wide Slash; at 30% enrage and its emote.
        // (Ossirian's line is a zone yell, type 6, heard by the whole copy in CMaNGOS; here a yell's 300 yards: the
        // second character waits by him.)
        Boss("Kurinnaxx", 509, 15348, 0, [], [Stage(0, 16, [3391, 26524, 25646, 25814]),
            Stage(29, 2, [26527], [-1_000_002], null, null, (Scene s, Creature boss) {
                s.following = 1;
                s.moveHero(1, spawnOf(509, 15339));
            })], 0, 0, 2, Position.init, [classWarrior, classMage],
            (Scene s, Creature boss) {
                assert(s.all(andorov).length == 1 && s.all(kaldorei).length == 4, format!"Andorov %s, elites %s"(
                    s.all(andorov).length, s.all(kaldorei).length));
                assert(s.said(-1_509_022), "no Ossirian line at Kurinnaxx's death\n" ~ s.seen());
            }),
        // Moam: his emote; Drain Mana, Trample, Double Attack; at 90 s three Mana Fiends and stone.
        Boss("Moam", 509, 15340, 2, [], [Stage(0, 12, [25676, 15550, 18941]),
            Stage(0, 80, [25685], [-1_509_028], [[manaFiend, 3]]),
            Stage(0, 2, null, null, null, null, toDelegate(stone)),
            Stage(0, 1, null, null, null, null, toDelegate(awake))], -1_509_000),
        // Buru: Thorns, Dismember, Gathering Speed, Full Speed at 60 s; under 20% his transformation, Creeping
        // Plague, hatchlings.
        Boss("Buru the Gorger", 509, 15370, 3, [buruEgg], [Stage(0, 62, [25640, 96, 1834, 1557], [-1_509_002]),
            Stage(19, 8, [24721, 20512], null, [[hatchling, 1]])]),
        // Ayamiss: Poison Stinger, swarmers, Paralyze (a larva), Stinger Spray; at 70% she lands: Lash, Thrash; under
        // 20% Frenzy and its emote.
        Boss("Ayamiss", 509, 15369, 4, [], [Stage(0, 31, [25748, 25725, 25749], null, [[swarmer, 1]]),
            Stage(0, 0, null, null, null, null, (Scene s, Creature boss) {
                assert(s.cast_(25721), "no larva fed on the paralyzed\n" ~ s.seen()); // (it goes as it feeds)
            }),
            Stage(69, 12, [25852, 3391]),
            Stage(19, 2, [8269], [-1_000_002])], 0, 0, 2, Position.init, [classWarrior, classMage], null, 60),
        // Ossirian: Supreme, his line, a sand vortex; Cyclone (20 s), War Stomp, Curse of Tongues (30 s); a crystal
        // used by him weakens him.
        Boss("Ossirian", 509, ossirianEntry, 5, [], [Stage(0, 32, [25189, 25188, 25195], null, [[sandVortex, 1]]),
            Stage(0, 2, null, null, null, null, toDelegate(useCrystal)),
            Stage(0, 1, null, null, null, null, toDelegate(weakened))], -1_509_025, -1_509_027),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

/**
 * General Rajaxx's army: Kurinnaxx slain, General Andorov and his Kaldorei come and walk to the ruins' gates, where
 * he waits; asked, he speaks (his lines) and leads the attack: the copy's Rajaxx encounter is in progress and the
 * army's waves charge, each beaten bringing the next (Rajaxx's yells at the third to the seventh), then Rajaxx
 * himself (his line); his death ends it, and Andorov trades. Wowpedia: seven waves, then Rajaxx; Andorov and his
 * elites help, and sell to those who earned it.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint { andorovEntry = 15471, rajaxxEntry = 15341, gossipFlag = 1, vendorFlag = 0x80 }
    static immutable uint[9] armies = [15385, 15388, 15386, 15390, 15389, 15392, 15391, 15387, 15344];
    auto s = new Scene(509, Position(-8822, 1630, 21), [classWarrior, classMage]);
    s.run(1.seconds);
    s.kill(s.the(15348));
    s.run(2.seconds);
    auto andorov = s.the(andorovEntry);
    s.stayWith = andorov;
    s.stayWithin = 15;
    s.pressing = false;
    assert(s.runUntil(() => (andorov.values.get!UNIT_NPC_FLAGS & gossipFlag) != 0, 120.seconds),
        format!"Andorov does not wait at the gates (at %s)"(andorov.position));
    s.moveHeroes(andorov.position);
    s.run(400.msecs);
    s.forget();
    s.gossip(andorov, [0]);
    assert(s.runUntil(() => s.ask(1) == 1, 90.seconds), format!"the army does not come (Andorov at %s)\n%s"(
        andorov.position, s.seen()));
    foreach (line; [-1_509_004, -1_509_003, -1_509_029, -1_509_030])
        assert(s.said(line), format!"Andorov: line %s not said\n%s"(line, s.seen()));
    // The waves beaten one by one: every one of the army that fights is slain.
    auto rajaxx = s.the(rajaxxEntry);
    s.stayWith = null;
    const beaten = s.runUntil(() {
        foreach (entry; armies)
            foreach (c; s.all(entry))
                if (c.ai.inCombat)
                    s.kill(c);
        return rajaxx.ai.inCombat;
    }, 600.seconds, 1.seconds);
    assert(beaten, "Rajaxx never comes\n" ~ s.seen());
    foreach (line; [-1_509_005, -1_509_006, -1_509_007, -1_509_008, -1_509_009, -1_509_010])
        assert(s.said(line), format!"Rajaxx: line %s not said\n%s"(line, s.seen()));
    s.kill(rajaxx);
    s.run(2.seconds);
    assert(s.ask(1) == 3, "the Rajaxx encounter not done");
    assert(andorov.alive && (andorov.values.get!UNIT_NPC_FLAGS & vendorFlag), "Andorov does not trade");
}

// ---------------------------------------------------------------------------------------------------------------
// Temple of Ahn'Qiraj (531)
// ---------------------------------------------------------------------------------------------------------------

/**
 * The Prophet Skeram, Battleguard Sartura, Fankriss, Princess Huhuran, Ouro: each one's abilities, the copy's
 * encounter. Skeram at 75% splits into three (two images); his death opens his gate. Sartura enrages under 25%;
 * Huhuran goes berserk under 30%. Ouro comes up from his sand when it is disturbed, sweeps and blasts, and after 90 s
 * goes under, his dirt mounds chasing.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint { skeramEntry = 15263, spawnOfFankriss = 15630, hatchling = 15962, ouroEntry = 15517,
        ouroSpawner = 15957, dirtMound = 15712 }
    const Boss[] bosses = [
        // Skeram: his line; Arcane Explosion (two in melee: one in ten of the raid and one more), True Fulfillment
        // (the second on his threat); at 75% two images (his health then, shared).
        Boss("The Prophet Skeram", 531, skeramEntry, 0, [], [Stage(0, 16, [26192, 785]),
            Stage(74, 3, null, null, [[skeramEntry, 3]])], -1_531_000, -1_531_002, 2, Position.init,
            [classWarrior, classMage], (Scene s, Creature boss) {
                assert(s.doorOpen(180636), "Skeram's gate shut after his death");
                assert(s.all(skeramEntry).length == 0, "his images outlive him");
            }),
        // Sartura: her line; Sundering Cleave, Whirlwind; under 25% enrage and its emote.
        Boss("Battleguard Sartura", 531, 15516, 2, [], [Stage(0, 20, [25174, 26083]),
            Stage(24, 2, [8269], [-1_000_002])], -1_531_008, -1_531_010),
        // Fankriss: Mortal Wound; an entangle (720, 731 or 1121) at someone not his victim and two Vekniss
        // Hatchlings there; Spawns of Fankriss (30 .. 50 s).
        Boss("Fankriss the Unyielding", 531, 15510, 3, [], [Stage(0, 52, [25646], null,
            [[spawnOfFankriss, 1], [hatchling, 2]])]),
        // Huhuran: Acid Spit, Noxious Poison, Frenzy (25 .. 35 s; its emote), Wyvern Sting; under 30% Berserk.
        Boss("Princess Huhuran", 531, 15509, 5, [], [Stage(0, 46, [26050, 26053, 26051, 26180], [-1_000_001]),
            Stage(29, 2, [26068], [-1_000_004])]),
        // Ouro: his sand disturbed, he comes up (Birth); Sweep (20 s), Sand Blast (25 s); at 90 s under the sand,
        // his dirt mounds after the raid; under 20% Berserk. A wipe sends him back under (his sand wakes again).
        Boss("Ouro", 531, ouroEntry, 7, [ouroSpawner], [Stage(0, 33, [26586, 26103, 26102]),
            Stage(0, 62, [26063], null, [[dirtMound, 1]]),
            Stage(19, 33, [26615])], 0, 0, 2, Position.init, [classWarrior, classMage], null, 20, true, null,
            spawnOf(531, ouroSpawner), (Scene s) {
                auto spawner = s.the(ouroSpawner);
                s.moveHeroes(spawner.position);
                s.engage(spawner);
                assert(s.runUntil(() => s.find(ouroEntry) !is null, 5.seconds), "Ouro does not come up");
                return s.the(ouroEntry);
            }),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

/**
 * The Bug Trio: Lord Kri, Princess Yauj and Vem fight together; the first two to fall are devoured by the others
 * (the emote; they heal fully) and the encounter goes on; the last one dies, and it is done. Their own: Kri's
 * Cleave and Toxic Volley, Vem's Knock Away and Knockdown, Yauj's Fear and Ravage. Wowpedia: when one dies the
 * others are healed to full.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint kri = 15511, yauj = 15543, vem = 15544;
    auto at = spawnOf(531, kri);
    auto s = new Scene(531, Position(at.x + 3, at.y, at.z), [classWarrior, classMage]);
    s.run(1.seconds);
    auto k = s.the(kri), y = s.the(yauj), v = s.the(vem);
    s.clear(k.position, 60, [kri, yauj, vem]);
    s.stayWith = k;
    s.stayWithin = 15;
    foreach (c; [k, y, v])
        s.engage(c);
    s.run(1.seconds);
    assert(s.ask(1) == 1, "the trio's encounter not in progress");
    s.run(24.seconds);
    foreach (pair; [[kri, 26350], [kri, 25812], [vem, 18670], [vem, 19128], [yauj, 26580], [yauj, 3242]])
        assert(s.castBy(pair[0], pair[1]), format!"%s: %s not cast\n%s"(pair[0], pair[1], s.seen()));
    // Kri falls first: devoured, the others whole again.
    s.hurtTo(y, 50);
    s.hurtTo(v, 50);
    s.kill(k);
    s.run(4.seconds);
    assert(s.said(-1_531_048), "no emote as Kri is devoured\n" ~ s.seen());
    assert(s.find(kri) is null, "Kri not gone");
    assert(s.healthOf(y) >= 100 && s.healthOf(v) >= 100, "the others not healed");
    assert(s.ask(1) == 1, "the encounter over with two alive");
    // Vem next; then Yauj, the last, dies.
    s.stayWith = y;
    s.kill(v);
    s.run(4.seconds);
    assert(s.find(vem) is null && y.alive, "Vem not devoured");
    s.kill(y);
    s.run(2.seconds);
    assert(!y.alive && s.ask(1) == 3, format!"Yauj does not die, or the encounter is not done (%s)"(s.ask(1)));
}

/**
 * Viscidus: Poison Shock, Poisonbolt Volley; frost slows him (100 hits: the emote), slows him more (150), freezes
 * him (200); struck 150 times frozen he shatters into globs (a glob for each 5% of his health) that crawl back;
 * those slain do not come back, and with none back he dies. Wowpedia: 200 frost hits to freeze, 150 melee hits to
 * shatter; he reforms with the health of the globs that reach him.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint viscidusEntry = 15299, glob = 15667, frostbolt = 116;
    const b = Boss("Viscidus", 531, viscidusEntry, 4, [], null);
    Scene s;
    auto viscidus = setUp(b, s);
    s.engage(viscidus);
    s.run(16.seconds);
    assert(s.castBy(viscidusEntry, 25993) && s.castBy(viscidusEntry, 25991), "no Poison Shock or Volley\n" ~ s.seen());
    s.hurtTo(viscidus, 50);
    // Frost until he freezes (a resisted bolt does not count: some more than 200).
    foreach (k; 0 .. 400)
    {
        if (s.said(-1_531_043))
            break;
        s.castTriggered(1, frostbolt, viscidus.guid);
        if (k % 10 == 0)
            s.run(200.msecs);
    }
    s.run(1.seconds);
    foreach (line; [-1_531_041, -1_531_042, -1_531_043])
        assert(s.said(line), format!"Viscidus: line %s not said (frost)\n%s"(line, s.seen()));
    s.pressing = false;
    foreach (k; 0 .. 150)
        s.engage(viscidus); // a blow from each
    s.run(1.seconds);
    assert(s.said(-1_531_046), "Viscidus does not shatter\n" ~ s.seen());
    auto globs = s.all(glob);
    assert(globs.length >= 9, format!"%s globs (half his health: ten)"(globs.length));
    foreach (g; globs)
        s.kill(g);
    assert(s.runUntil(() => !viscidus.alive, 10.seconds), "every glob slain, but Viscidus lives on");
    assert(s.ask(4) == 3, "his encounter not done");
}

/**
 * The Twin Emperors: their lines; Vek'lor's Shadow Bolt, Blizzard and Arcane Burst, Vek'nilash's Uppercut and
 * Unbalancing Strike; one health between them (a blow to one is felt by both); at 35 s they swap places; one slain,
 * both die. Wowpedia: they share health, teleport every 30-35 s, and heal each other when close.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint veklor = 15276, veknilash = 15275;
    auto at = spawnOf(531, veknilash);
    auto s = new Scene(531, Position(at.x + 3, at.y, at.z), [classWarrior, classMage]);
    s.run(1.seconds);
    auto lor = s.the(veklor), nilash = s.the(veknilash);
    s.clear(nilash.position, 100, [veklor, veknilash]);
    s.engage(nilash);
    s.engage(lor);
    s.stayWith = nilash;
    s.stayWithin = 200; // the mage reaches Vek'lor from afar
    s.run(1.seconds);
    assert(s.ask(6) == 1, "the twins' encounter not in progress");
    assert(s.texts.length >= 2, "their aggro lines\n" ~ s.seen());
    s.run(36.seconds);
    foreach (pair; [[veklor, 26006], [veklor, 568], [veknilash, 26613]])
        assert(s.castBy(pair[0], pair[1]), format!"%s: %s not cast\n%s"(pair[0], pair[1], s.seen()));
    assert(s.castBy(veklor, 800) || s.castBy(veknilash, 800), "they do not swap\n" ~ s.seen());
    s.hurtTo(nilash, 60);
    s.run(1.seconds);
    // (shared, then healed by his brother's Heal Brother as they stand close: a few points over)
    assert(s.healthOf(lor) < 70, format!"Vek'lor at %s%%: the blow not shared"(s.healthOf(lor)));
    s.kill(nilash);
    s.run(2.seconds);
    assert(!lor.alive && !nilash.alive, "one slain, the other lives");
    assert(s.said(-1_531_024) && s.said(-1_531_031), "their death lines\n" ~ s.seen());
    assert(s.ask(6) == 3 && s.doorOpen(180635), "the encounter not done, or the way out shut");
}

/**
 * C'Thun: the Eye fights first (Eye Beam, Dark Glare at 48 s, a Claw Tentacle at 8 s, eight Eye Tentacles at 45 s);
 * slain, C'Thun rises (his carapace), sends a Giant Claw Tentacle (10 s), eight Eye Tentacles (35 s), a Giant Eye
 * Tentacle (40 s), and swallows players into his stomach (Mouth Tentacle, then the stomach's Digestive Acid), where
 * two Flesh Tentacles grow; both slain, he is weakened (the emote, Vulnerable); his death ends it.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint
    {
        eyeEntry = 15589, cthunEntry = 15727, claw = 15725, eyeTentacle = 15726, giantClaw = 15728, giantEye = 15334,
        flesh = 15802,
    }
    const b = Boss("Eye of C'Thun", 531, eyeEntry, 8, [cthunEntry], null);
    Scene s;
    auto eye = setUp(b, s);
    auto cthun = s.the(cthunEntry);
    s.stayWithin = 40;
    s.engage(eye);
    s.run(50.seconds);
    assert(s.ask(8) == 1, "the encounter not in progress");
    assert(s.castBy(eyeEntry, 32950) || s.castBy(eyeEntry, 26134), "no Eye Beam\n" ~ s.seen());
    assert(s.castBy(eyeEntry, 26029), "no Dark Glare\n" ~ s.seen());
    assert(s.all(claw).length >= 1 && s.all(eyeTentacle).length >= 8, format!"tentacles: %s claws, %s eyes"(
        s.all(claw).length, s.all(eyeTentacle).length));
    s.kill(eye);
    s.stayWith = cthun;
    s.forget();
    s.run(50.seconds);
    assert(s.castBy(cthunEntry, 26156) || cthun.auras.find(26156) !is null, "C'Thun without his carapace");
    assert(s.all(giantClaw).length >= 1 && s.all(giantEye).length >= 1,
        format!"%s giant claws, %s giant eyes"(s.all(giantClaw).length, s.all(giantEye).length));
    assert(s.cast_(26332), "no one seized by a Mouth Tentacle\n" ~ s.seen());
    assert(s.all(flesh).length == 2, format!"%s Flesh Tentacles"(s.all(flesh).length));
    foreach (f; s.all(flesh))
        s.kill(f);
    s.run(2.seconds);
    assert(cthun.auras.find(26235) !is null, "C'Thun not weakened, his Flesh Tentacles slain");
    s.kill(cthun);
    s.run(2.seconds);
    assert(s.ask(8) == 3, "his encounter not done");
}

// ---------------------------------------------------------------------------------------------------------------
// Naxxramas (533)
// ---------------------------------------------------------------------------------------------------------------

/**
 * The bosses of the four quarters fought one at a time: each one's abilities by its timers and thresholds, what
 * it calls, its encounter. Anub'Rekhan: Impale, a Crypt Guard at 20 s, Locust Swarm (80 .. 120 s). Faerlina: Poison
 * Bolt Volley, Rain of Fire, Enrage at 60 s. Maexxna: Poison Shock, Necrotic Poison, Web Wrap (20 s), Web Spray
 * (40 s), spiderlings (30 s), Frenzy under 30%. Noth: Curse, Blink, his Plagued Warriors (12 s), to his balcony at
 * 90 s. Heigan: Mana Burn, Decrepit Fever, to his platform at 90 s (Plague Cloud). Loatheb: Corrupted Mind, his
 * Remove Curse, spores (13 s), Inevitable Doom at two minutes. Razuvious: Disrupting Shout, Unbalancing Strike.
 * Gothik: his trainees at 24 s, down among the raid at 4:34 (Shadow Bolt, Harvest Soul). Patchwerk: Hateful Strike; under 5% Enrage. Grobbulus: Mutating Injection, Slime
 * Spray and its slimes, his poison clouds. Gluth: Mortal Wound, Frenzy, Terrifying Roar, his zombies, Decimate at
 * 105 s.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint
    {
        cryptGuard = 16_573, spiderling = 17_055, webWrap = 16_486, plaguedWarrior = 16_984, spore = 16_286,
        trainee = 16_124, falloutSlime = 16_290, grobbulusCloud = 16_363, zombieChow = 16_360,
    }
    const Boss[] bosses = [
        Boss("Anub'Rekhan", 533, 15_956, 0, [], [Stage(0, 22, [28_783], null, [[cryptGuard, 1]]),
            Stage(0, 100, [28_785])]),
        Boss("Grand Widow Faerlina", 533, 15_953, 1, [], [Stage(0, 62, [28_796, 28_794, 28_798])]),
        Boss("Maexxna", 533, 15_952, 2, [], [Stage(0, 42, [28_741, 28_776, 29_484], null, [[spiderling, 1]]),
            Stage(29, 2, [28_747])]),
        Boss("Noth the Plaguebringer", 533, 15_954, 3, [], [Stage(0, 32, [29_208, 29_213], null,
            [[plaguedWarrior, 1]]), Stage(0, 60, [29_230])]),
        Boss("Heigan the Unclean", 533, 15_936, 4, [], [Stage(0, 22, [29_998, 29_310]), Stage(0, 70, [29_350])]),
        Boss("Loatheb", 533, 16_011, 5, [], [Stage(0, 16, [29_201, 30_281], null, [[spore, 1]]),
            Stage(0, 106, [29_204])]),
        Boss("Instructor Razuvious", 533, 16_061, 6, [], [Stage(0, 32, [29_107, 26_613])]),
        Boss("Gothik the Harvester", 533, 16_060, 7, [], [Stage(0, 26, null, null, [[trainee, 1]]),
            // at 4:34 he comes down (the gate opens: "special"): Shadow Bolt, Harvest Soul
            Stage(0, 255, [29_317, 28_679], null, null, null, null)], 0, 0, 2, Position.init,
            [classWarrior, classMage], (Scene s, Creature boss) {}, 60),
        Boss("Patchwerk", 533, 16_028, 9, [], [Stage(0, 5, [28_308]), Stage(4, 2, [28_131])]),
        Boss("Grobbulus", 533, 15_931, 10, [], [Stage(0, 32, [28_169, 28_157], null,
            [[falloutSlime, 1], [grobbulusCloud, 1]])]),
        // Check the first spawn before the later Devour ticks may eat it and the following waves.
        Boss("Gluth", 533, 15_932, 11, [], [Stage(0, 6, null, null, [[zombieChow, 1]]),
            Stage(0, 16, [25_646, 28_371, 29_685]), Stage(0, 85, [28_374])]),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

/**
 * The Four Horsemen: each one's mark (20 s) and special (15 s); each that dies leaves its spirit; the four slain,
 * the encounter is done and their chest appears.
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[4][4] horsemen = [ // entry, mark, special, spirit
        [16_065, 28_833, 28_863, 28_931], [16_062, 28_834, 28_882, 28_928], [16_064, 28_832, 28_884, 28_932],
        [16_063, 28_835, 28_883, 28_934]];
    auto at = spawnOf(533, horsemen[0][0]);
    auto s = new Scene(533, Position(at.x + 3, at.y, at.z), [classWarrior, classMage]);
    s.run(1.seconds);
    Creature[4] four;
    foreach (i, h; horsemen)
        four[i] = s.the(h[0]);
    s.clear(four[0].position, 60, [16_065, 16_062, 16_064, 16_063]);
    foreach (h; four)
        s.engage(h);
    s.stayWith = four[0];
    s.stayWithin = 60;
    s.run(22.seconds);
    assert(s.ask(8) == 1, "the encounter not in progress");
    foreach (h; horsemen)
        assert(s.castBy(h[0], h[1]) && s.castBy(h[0], h[2]), format!"horseman %s: mark %s or special %s not cast\n%s"(
            h[0], h[1], h[2], s.seen()));
    s.stayWith = null;
    foreach (i, h; four)
    {
        s.kill(h);
        s.run(1.seconds);
        assert(s.cast_(horsemen[i][3]), format!"horseman %s left no spirit"(horsemen[i][0]));
        if (i < 3)
            assert(s.ask(8) != 3, "the encounter done with a horseman alive");
    }
    s.run(2.seconds);
    assert(s.ask(8) == 3, "the four slain, the encounter not done");
    assert(s.objects(181_366).length, "no chest of the Four Horsemen");
}

/**
 * Thaddius: Stalagg and Feugen fall (each a fake death; the other's death within the window keeps both down), then
 * Thaddius wakes: Polarity Shift (15 s), Chain Lightning, Ball Lightning when no one is in his reach.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint stalagg = 15_929, feugen = 15_930, thaddiusEntry = 15_928;
    auto at = spawnOf(533, stalagg);
    auto s = new Scene(533, Position(at.x + 3, at.y, at.z), [classWarrior, classMage]);
    s.run(1.seconds);
    auto st = s.the(stalagg), fe = s.the(feugen), th = s.the(thaddiusEntry);
    s.clear(th.position, 100, [stalagg, feugen, thaddiusEntry]);
    s.engage(st);
    s.engage(fe);
    s.run(16.seconds);
    assert(s.ask(12) == 1, "the encounter not in progress");
    s.kill(st);
    s.kill(fe);
    s.run(2.seconds);
    assert(s.ask(12) == 4, format!"both adds down, but the encounter is %s"(s.ask(12)));
    s.run(6.seconds);
    assert(!st.alive && !fe.alive, format!"an add rose again (Stalagg %s, Feugen %s)"(st.alive, fe.alive));
    s.stayWith = th;
    assert(s.runUntil(() => th.ai.inCombat, 30.seconds), "Thaddius does not wake");
    s.forget();
    s.run(30.seconds);
    foreach (spell; [28_089, 28_167])
        assert(s.castBy(thaddiusEntry, spell), format!"Thaddius: %s not cast\n%s"(spell, s.seen()));
    s.kill(th);
    s.run(2.seconds);
    assert(s.ask(12) == 3, "his encounter not done");
}

/// Both actual platform spawns pull the opposite tank. Movement packets, threat and pickup agree.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.movement : jumpGravity, MovementFlags, MovementInfo;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.unit : Blow, dealDamage;
    import std.algorithm.comparison : min;

    enum uint stalagg = 15_929, feugen = 15_930;
    const west = spawnOf(533, stalagg), east = spawnOf(533, feugen);
    const middle = Position((west.x + east.x) / 2, (west.y + east.y) / 2, west.z);
    auto s = new Scene(533, middle, [classWarrior, classWarrior, classWarrior]);
    auto st = s.the(stalagg), fe = s.the(feugen);
    s.clear(middle, 100, [stalagg, feugen]);
    s.moveHero(0, st.position);
    s.moveHero(1, fe.position);
    s.moveHero(2, st.position);
    dealDamage(s.heroUnit(0), s.map.unitOf(st), 1, Blow.spell());
    dealDamage(s.heroUnit(1), s.map.unitOf(fe), 1, Blow.spell());
    st.ai.addThreat(s.heroUnit(0), 1_000);
    fe.ai.addThreat(s.heroUnit(1), 1_500);
    st.ai.addThreat(s.heroUnit(2), 250);
    s.run(20.seconds);
    assert(st.ai.hostVictim.guid == s.hero(0).guid && fe.ai.hostVictim.guid == s.hero(1).guid);
    assert(!s.cast_(28_337), "the exchange is not due yet");

    MovementInfo[2] flights;
    long[2] launched;
    foreach (_; 0 .. 24)
    {
        s.w.now += 200.msecs;
        s.elapsedMs += 200;
        s.w.context.update(s.w.now);
        foreach (k, ref flight; flights)
        {
            auto packets = s.heroes[k].read();
            s.note(packets, k == 0);
            foreach (packet; packets)
                if (packet.opcode == Opcode.SMSG_MOVE_KNOCK_BACK)
                {
                    assert(!launched[k], "one movement order per tank");
                    auto r = ByteReader(packet.body_);
                    const who = r.readPackedGuid(), order = r.read!uint;
                    assert(who == s.hero(k).guid);
                    flight.jumpCos = r.read!float;
                    flight.jumpSin = r.read!float;
                    flight.jumpXySpeed = r.read!float;
                    flight.jumpVelocity = r.read!float;
                    flight.flags = MovementFlags.jumping;
                    flight.position = s.hero(k).position;
                    ByteWriter ack;
                    ack.put(who);
                    ack.put(order);
                    flight.write(ack);
                    s.heroes[k].write(Opcode.CMSG_MOVE_KNOCK_BACK_ACK, ack.data);
                    launched[k] = s.elapsedMs;
                }
            if (!launched[k] || s.elapsedMs <= launched[k] || !flight.flags)
                continue;
            const elapsed = (s.elapsedMs - launched[k]) / 1000.0f;
            const duration = -2 * flight.jumpVelocity / jumpGravity; // the platforms have the same elevation
            const t = min(elapsed, duration);
            auto travel = flight;
            travel.position.x += t * flight.jumpXySpeed * flight.jumpCos;
            travel.position.y += t * flight.jumpXySpeed * flight.jumpSin;
            travel.position.z -= t * (flight.jumpVelocity + jumpGravity * t / 2);
            const landing = elapsed >= duration;
            if (landing)
                flight.flags = travel.flags = MovementFlags.none;
            ByteWriter body_;
            travel.write(body_);
            s.heroes[k].write(landing ? Opcode.MSG_MOVE_FALL_LAND : Opcode.MSG_MOVE_HEARTBEAT, body_.data);
        }
    }

    assert(launched[0] && launched[0] == launched[1], format!"two simultaneous pulls expected: %s, %s\n%s"(
        launched[0], launched[1], s.seen()));
    assert(s.castBy(stalagg, 28_338) && s.castBy(feugen, 28_339));
    assert(Scene.distance(s.hero(0).position, fe.position) < 5 && Scene.distance(s.hero(1).position, st.position) < 5,
        format!"tanks landed at %s and %s, bosses at %s and %s"(s.hero(0).position, s.hero(1).position, st.position, fe.position));
    assert(st.ai.threatOf(s.hero(0).guid) == 0 && fe.ai.threatOf(s.hero(1).guid) == 0, "the old tank loses threat on each add");
    assert(st.ai.threatOf(s.hero(2).guid) == 250 && st.ai.hostVictim.guid == s.hero(2).guid,
        "the other player's existing threat still matters");
    assert(fe.ai.hostVictim.guid == s.hero(0).guid, "an uncontested tank can pick up the opposite add");
    st.ai.taunt(s.heroUnit(1), s.map);
    assert(st.ai.hostVictim.guid == s.hero(1).guid && st.ai.threatOf(s.hero(1).guid) == 250,
        "the incoming tank can taunt off the backup");
}

/**
 * Sapphiron: the Frostwyrm Lair's way open (the copy's "special"), he comes 22 s later and fights all there:
 * Frost Aura, Cleave, Tail Sweep, Life Drain, his blizzard; at 46 s he takes to the air (Icebolt) and lands. His
 * The air phase ends in Frost Breath and the ice blocks melt.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint sapphironEntry = 15_989;
    auto s = new Scene(533, Position(3521.48f, -5225.87f, 137.626f), [classWarrior, classMage]);
    s.run(1.seconds);
    s.signalCopy(13, 4);
    assert(s.runUntil(() => s.find(sapphironEntry) !is null, 30.seconds), "no Sapphiron");
    auto sap = s.the(sapphironEntry);
    s.stayWith = sap;
    s.stayWithin = 60;
    assert(s.runUntil(() => sap.ai.inCombat, 10.seconds), "Sapphiron does not fight");
    s.run(17.seconds);
    foreach (spell; [28_529, 19_983, 15_847, 28_542, 28_560])
        assert(s.castBy(sapphironEntry, spell), format!"Sapphiron: %s not cast\n%s"(spell, s.seen()));
    s.forget();
    s.run(50.seconds);
    assert(s.castBy(sapphironEntry, 28_522), "Sapphiron: no Icebolt from the air\n" ~ s.seen());
    assert(s.objects(181247).length, "no ice block during the air phase");
    s.run(16.seconds);
    assert(s.castBy(sapphironEntry, 28524), "no damaging Frost Breath");
    assert(!s.objects(181247).length, "block remained after landing");
    s.kill(sap);
    s.run(2.seconds);
    assert(s.ask(13) == 3, "his encounter not done");
}

/**
 * Kel'Thuzad: the trigger in his chamber (4112) begins it: he channels while his minions come from the alcoves
 * (Soldiers of the Frozen Wastes at once, Unstoppable Abominations at 30 s, Soul Weavers at 40 s); at 5:25 he
 * fights: Frostbolt, Frost Nova, Mana Detonation, Shadow Fissure, Frost Blast; under 40% the Guardians of
 * Icecrown come. Wowpedia: phase two after about 3.5 minutes (or the adds' deaths); four or five Guardians in the
 * third.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint { ktEntry = 15_990, soldier = 16_427, abomination = 16_428, weaver = 16_429, guardian = 16_441 }
    auto at = spawnOf(533, ktEntry);
    auto s = new Scene(533, Position(at.x + 3, at.y, at.z), [classWarrior, classMage]);
    s.run(1.seconds);
    auto kt = s.the(ktEntry);
    s.signalCopy(1000 + 4112, 0);
    s.run(1.seconds);
    assert(s.ask(14) == 1, format!"the trigger did not begin it (%s)"(s.ask(14)));
    s.run(41.seconds);
    foreach (e; [soldier, abomination, weaver])
        assert(s.all(e).length, format!"no minion %s from the alcoves"(e));
    // His minions slain as they come, till he fights.
    s.stayWith = kt;
    s.stayWithin = 30;
    const fights = s.runUntil(() {
        foreach (e; [soldier, abomination, weaver])
            foreach (m; s.all(e))
                s.kill(m);
        return kt.ai.inCombat && (kt.values.get!UNIT_FIELD_FLAGS & 0x0200_0000) == 0;
    }, 330.seconds, 1.seconds);
    assert(fights, "Kel'Thuzad never fights");
    s.forget();
    s.run(61.seconds);
    foreach (spell; [28_478, 28_479, 27_819, 27_810, 27_808, 28_408])
        assert(s.castBy(ktEntry, spell), format!"Kel'Thuzad: %s not cast\n%s"(spell, s.seen()));
    s.hurtTo(kt, 39);
    s.run(8.seconds);
    assert(s.all(guardian).length >= 1, "no Guardian of Icecrown under 40%");
    s.kill(kt);
    s.run(2.seconds);
    assert(s.ask(14) == 3, "his encounter not done");
}

// ---------------------------------------------------------------------------------------------------------------
// World bosses
// ---------------------------------------------------------------------------------------------------------------

/**
 * Lord Kazzak (Blasted Lands) and Azuregos (Azshara), where the world database spawns them; and the four dragons of
 * the Emerald Dream, which this world database spawns nowhere (no `creature` row, no spawn group: they are summoned
 * here, in Duskwood's Twilight Grove). Kazzak: one of his two aggro lines; Shadow Bolt Volley, Cleave, Thunderclap,
 * Mark of Kazzak (25 s), Void Bolt (30 s), Twisted Reflection (33 s); his death line. Azuregos: Mark of Frost, Frost
 * Breath, Cleave, Mana Storm, Chill, Reflection, Arcane Vacuum at 30 s with his line. The dragons: Mark of Nature at
 * the pull, Noxious Breath, Tail Sweep, Seeping Fog at 30 s, their own spell, and at 75% their special (with its
 * line): Emeriss' Corruption of the Earth, Lethon's Draw Spirit (his spirit shades), Taerar's banishment (his shades),
 * Ysondre's demented druids.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint { spiritShade = 15_261, shadeOfTaerar = 15_302, dementedDruid = 15_260 }
    auto kazzakAggro = (Scene s, Creature boss) {
        assert(s.said(-1_000_148) || s.said(-1_000_149), "Kazzak: no aggro line\n" ~ s.seen());
    };
    const grove = Position(-10_428, -392, 44.4f);
    uint[] dragon = [24_818, 15_847, 24_813, 24_814, 25_041];
    const Boss[] bosses = [
        Boss("Lord Kazzak", 0, 12_397, -1, [], [Stage(0, 0, null, null, null, null, toDelegate(kazzakAggro)),
            Stage(0, 34, [21_341, 20_691, 26_554, 21_056, 21_066, 21_063])], 0, -1_000_155),
        Boss("Azuregos", 1, 6109, -1, [], [Stage(0, 32, [23_184, 21_099, 19_983, 21_097, 21_098, 22_067, 21_147],
            [-1_000_100])]),
        Boss("Emeriss", 0, 14_889, -1, [], [Stage(0, 31, dragon ~ [24_928u]),
            Stage(74, 2, [24_910], [-1_000_402])], -1_000_401, 0, 2, grove),
        Boss("Lethon", 0, 14_888, -1, [], [Stage(0, 31, dragon ~ [24_834u]),
            Stage(74, 2, [24_811], [-1_000_667], [[spiritShade, 1]])], -1_000_666, 0, 2, grove),
        Boss("Taerar", 0, 14_890, -1, [], [Stage(0, 31, dragon ~ [24_857u, 22_686u]),
            Stage(74, 2, [24_883], [-1_000_400], [[shadeOfTaerar, 1]])], -1_000_399, 0, 2, grove),
        Boss("Ysondre", 0, 14_887, -1, [], [Stage(0, 31, dragon ~ [24_819u]),
            Stage(74, 2, [24_796], [-1_000_361], [[dementedDruid, 1]])], -1_000_360, 0, 2, grove),
    ];
    foreach (b; bosses)
    {
        fight(b);
        wipe(b);
    }
}

/**
 * High Priest Thekal and Zealots Lor'Khan and Zath: brought down, each lies as if dead and rises in ten seconds
 * (Resurrect, whole again) unless all three are down together; then Thekal rises as the tiger (Tiger Form, list
 * 1450902: Force Punch, Charge, Speed Slash, Frenzy), and his death ends it (his line; the Zealots go). Wowpedia: the
 * three must die within ten seconds of each other, then Thekal's tiger phase.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint thekalEntry = 14_509, lorkhan = 11_347, zath = 11_348;
    const b = Boss("High Priest Thekal", 309, thekalEntry, 3, [lorkhan, zath], null);
    Scene s;
    auto thekal = setUp(b, s);
    auto lk = s.the(lorkhan), z = s.the(zath);
    s.stayWithin = 20;
    foreach (c; [thekal, lk, z])
        s.engage(c);
    s.run(2.seconds);
    assert(s.said(-1_309_009), "no aggro line\n" ~ s.seen());
    assert(s.ask(3) == 1, "his encounter not in progress");
    // Alone brought down, he rises again whole.
    s.kill(thekal);
    s.run(1.seconds);
    assert(thekal.alive && s.ask(3) == 4, format!"Thekal not down as if dead (%s)"(s.ask(3)));
    assert(s.runUntil(() => s.ask(3) == 1 && s.healthOf(thekal) >= 100, 12.seconds), "Thekal does not rise");
    assert(s.castBy(thekalEntry, 24_173), "no Resurrect\n" ~ s.seen());
    // All three down together: the tiger.
    s.forget();
    foreach (c; [lk, z, thekal])
        s.kill(c);
    assert(s.runUntil(() => s.castBy(thekalEntry, 24_169), 20.seconds), "no Tiger Form\n" ~ s.seen());
    s.run(16.seconds);
    assert(lk.alive && z.alive && s.ask(6) == 4 && s.ask(7) == 4, "the Zealots rose again");
    foreach (spell; [24_189, 24_408])
        assert(s.castBy(thekalEntry, spell), format!"the tiger: %s not cast\n%s"(spell, s.seen()));
    s.kill(thekal);
    s.run(2.seconds);
    assert(!thekal.alive && s.ask(3) == 3 && s.said(-1_309_010), "his death\n" ~ s.seen());
}

/**
 * The Gong of Bethekk: struck, High Priestess Arlokk comes ten seconds later (`dbscripts_on_event` 9066) and her
 * encounter is under way (the forcefield up, her prowlers sent from the panther triggers); her line; list 1451501
 * (Mark of Arlokk, Shadow Word: Pain, Gouge); at 30 s the panther (24190; list 1451502: Ravage, Whirlwind, Vanish);
 * her death opens the forcefield (her line). A wipe sends her away until the gong is struck again.
 */
unittest
{
    if (!haveRealData())
        return;
    enum : uint { arlokkEntry = 14_515, gong = 180_526, prowler = 15_101, forcefield = 180_497 }
    auto gongAt = objectSpawnOf(309, gong);
    auto arrive = (Scene s) {
        auto g = s.objects(gong);
        assert(g.length, "no Gong of Bethekk");
        s.use(g[0]);
        assert(s.runUntil(() => s.find(arlokkEntry) !is null, 15.seconds), "the gong called no Arlokk");
        return s.the(arlokkEntry);
    };
    auto shut = (Scene s, Creature boss) {
        assert(!s.doorOpen(forcefield), "the forcefield down while she fights");
    };
    const b = Boss("High Priestess Arlokk", 309, arlokkEntry, 4, [prowler], [
        Stage(0, 2, null, null, null, null, toDelegate(shut)),
        Stage(0, 16, [24_210, 24_212, 12_540], null, [[prowler, 1]]),
        Stage(0, 30, [24_190, 24_213, 24_236, 24_223])], -1_309_011, -1_309_013, 2, Position.init,
        [classWarrior, classMage], (Scene s, Creature boss) {
            assert(s.doorOpen(forcefield), "the forcefield up after her death");
        }, 10, true, null, Position(gongAt.x + 3, gongAt.y, gongAt.z), toDelegate(arrive));
    fight(b);
    wipe(b);
}

// ---------------------------------------------------------------------------------------------------------------
// The raids' scripted trash
// ---------------------------------------------------------------------------------------------------------------

/**
 * The Temple's Anubisath Sentinels: a group pulled, each takes one of the nine abilities (none twice); one slain
 * shares its own with the others (the emote); under 30% one frenzies (its emote). Wowpedia: "each Sentinel has a
 * random ability ... when one dies, the others gain its ability".
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint sentinel = 15_264;
    static immutable uint[9] abilities = [812, 2147, 2148, 2834, 9347, 13_022, 19_595, 21_737, 25_777];
    const b = Boss("Anubisath Sentinel", 531, sentinel, -1, [sentinel], null);
    Scene s;
    auto first = setUp(b, s);
    Creature[] group;
    foreach (c; s.all(sentinel))
        if (Scene.distance(c.position, first.position) < 80)
            group ~= c;
    assert(group.length >= 2, format!"%s sentinels together"(group.length));
    s.engage(first);
    s.run(2.seconds);
    uint[] taken;
    size_t abilityCount(Creature c)
    {
        size_t n;
        foreach (a; abilities)
            n += c.auras.find(a) !is null;
        return n;
    }
    foreach (c; group)
    {
        uint mine;
        foreach (a; abilities)
            if (c.auras.find(a) !is null)
                mine = a;
        assert(mine, "a sentinel without its ability");
        assert(!taken.canFind(mine), format!"two sentinels with %s"(mine));
        taken ~= mine;
    }
    s.kill(first);
    s.run(1.seconds);
    assert(s.said(-1_531_047), "no emote as the powers are shared\n" ~ s.seen());
    foreach (c; group[1 .. $])
        assert(abilityCount(c) == 2, "a sentinel did not take the fallen one's ability");
    s.hurtTo(group[1], 29);
    s.run(1.seconds);
    assert(s.castBy(sentinel, 8599) && s.said(-1_000_002), "no frenzy under 30%\n" ~ s.seen());
}

/**
 * Naxxramas' Stoneskin Gargoyles (stone till pulled; Acid Volley; Stoneskin under 30%) and Living Poison (it explodes
 * near a player).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint gargoyle = 16_168, livingPoison = 16_027;
    const b = Boss("Stoneskin Gargoyle", 533, gargoyle, -1, [], [Stage(0, 9, [29_325]), Stage(29, 2, [28_995])]);
    fight(b);
    // (No Living Poison is spawned in the data: the corridor's trigger sends them. One summoned by a player.)
    auto at = spawnOf(533, 16_028);
    auto s = new Scene(533, Position(at.x + 3, at.y, at.z), [classWarrior]);
    s.run(1.seconds);
    s.summon(livingPoison, Position(at.x + 4, at.y, at.z));
    assert(s.runUntil(() => s.cast_(28_433), 30.seconds), "no Living Poison explodes by a player\n" ~ s.seen());
}

/**
 * What bosses call again and again keeps coming when the raid slays it: Anub'Rekhan's Crypt Guards (one at 20 s, one
 * after each Locust Swarm), Ayamiss' swarmers (one every five seconds; they pass), an Anubisath Guardian's warriors
 * or swarmguards (one every fifteen). Each script keeps its calls in a few places, freed as they die; a slain one leaves
 * the map at once, and its place was never freed (`alive` of a creature not on the map is true), so after the first
 * few no more came.
 */
unittest
{
    if (!haveRealData())
        return;
    /// The creatures of `entries` that come in `seconds` of `b`'s fight, each slain as it comes.
    size_t called(const Boss b, const(uint)[] entries, uint seconds)
    {
        Scene s;
        auto boss = setUp(b, s);
        s.engage(boss);
        bool[ulong] seen;
        s.runUntil(() {
            foreach (e; entries)
                foreach (c; s.all(e))
                {
                    seen[c.guid] = true;
                    s.kill(c);
                }
            return false;
        }, seconds.seconds, 1.seconds);
        return seen.length;
    }
    const anub = called(Boss("Anub'Rekhan", 533, 15_956, 0), [16_573], 600);
    assert(anub >= 5, format!"Anub'Rekhan called %s Crypt Guards in ten minutes"(anub));
    const ayamiss = called(Boss("Ayamiss", 509, 15_369, 4, [], null, 0, 0, 2, Position.init,
        [classWarrior, classMage], null, 60), [15_546], 120);
    assert(ayamiss >= 18, format!"Ayamiss called %s swarmers in two minutes"(ayamiss));
    const guardian = called(Boss("Anubisath Guardian", 509, 15_355), [15_537, 15_538], 100);
    assert(guardian >= 5, format!"an Anubisath Guardian called %s in 100 s"(guardian));
}

/// A hatcher disturbs a single intact egg. Its hidden spawner hatches a whelp when a player reaches it.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : ActionResult;

    auto s = new Scene(229, Position(83.95f, -325.10f, 91.43f));
    auto eggs = s.objects(175124);
    assert(eggs.length);
    auto hatcher = s.summon(10683, eggs[0].position);
    assert(hatcher.ai.castFor(s.map, 15746, hatcher.guid, true) == ActionResult.ok);
    auto spawners = s.objects(175622);
    assert(spawners.length == 1 && s.objects(175124).length == eggs.length - 1);
    assert(Scene.distance(spawners[0].position, eggs[0].position) < 1);
    const before = s.all(10161).length;
    s.hero.movement.position = spawners[0].position;
    s.map.relocated(s.heroes[0].session.inWorld);
    assert(s.all(10161).length == before + 1 && s.map.findObject(spawners[0].guid) is null,
        format!"whelps %s -> %s, old spawner present %s, all spawners %s"(before, s.all(10161).length,
            s.map.findObject(spawners[0].guid) !is null, s.objects(175622).length));
}

/// Kurinnaxx places one visible trap under a player and springs it at that location four seconds later.
unittest
{
    import dmangos.script.api : ActionResult;

    if (!haveRealData())
        return;
    const origin = spawnOf(509, 15348);
    auto s = new Scene(509, origin, 2);
    auto boss = s.the(15348);
    s.moveHero(1, Position(origin.x + 10, origin.y, origin.z));
    s.run(100.msecs);
    assert(boss.ai.castFor(s.map, 26524, boss.guid, true) == ActionResult.ok);
    auto traps = s.objects(180647);
    assert(traps.length == 1, "one Sand Trap per cast");
    const at = traps[0].position;
    assert(Scene.distance(at, s.hero(0).position) < 0.1f || Scene.distance(at, s.hero(1).position) < 0.1f,
        "Sand Trap spawns at a player's feet");
    s.run(3900.msecs, 100.msecs);
    assert(s.map.gameObjectAt(traps[0].guid) !is null && !s.cast_(25656));
    s.run(100.msecs, 100.msecs);
    assert(s.map.gameObjectAt(traps[0].guid) is null && s.cast_(25656), "the trap springs after four seconds");
}

/// Each wave spares one floor section and erupts in the other three.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : ActionResult;

    static immutable tiles = [Position(2803.58f, -3675.67f, 273.666f), Position(2765.45f, -3663.31f, 273.667f),
        Position(2747.13f, -3684.35f, 274.352f), Position(2765.76f, -3718.73f, 274.317f)];
    auto s = new Scene(533, tiles[0], 4);
    auto wave = s.the(17293);
    foreach (k, tile; tiles)
        s.moveHero(k, tile);
    foreach (i; 0 .. tiles.length)
    {
        foreach (k; 0 .. tiles.length)
        {
            s.heroes[k].session.inWorld.godModeCheat = false;
            s.hero(k).values.set!UNIT_FIELD_MAXHEALTH(100_000);
            s.hero(k).values.set!UNIT_FIELD_HEALTH(100_000);
        }
        assert(wave.ai.castFor(s.map, cast(uint)(30116 + i), wave.guid, true) == ActionResult.ok);
        foreach (k; 0 .. tiles.length)
            assert((s.hero(k).values.get!UNIT_FIELD_HEALTH == 100_000) == (i == k),
                format!"wave %s section %s health %s"(i, k, s.hero(k).values.get!UNIT_FIELD_HEALTH));
        s.run(5.seconds);
    }
}

/// One Decimate lowers players and chows to 5%. It neither heals a low target nor hurts other NPCs.
unittest
{
    if (!haveRealData()) return;
    import dmangos.script.api : ActionResult;

    const origin = Position(3300, -3100, 300);
    auto s = new Scene(533, origin, [classWarrior, classMage, classWarrior]);
    auto gluth = s.summon(15932, origin);
    auto chow = s.summon(16360, origin);
    auto bystander = s.summon(16011, origin);
    const uint[3] initialHealth = [6_000, 400, 10_000];
    foreach (k, health; initialHealth)
    {
        s.heroes[k].session.inWorld.godModeCheat = false;
        s.hero(k).values.set!UNIT_FIELD_MAXHEALTH(10_000);
        s.hero(k).values.set!UNIT_FIELD_HEALTH(health);
    }
    chow.values.set!UNIT_FIELD_MAXHEALTH(4_000);
    chow.values.set!UNIT_FIELD_HEALTH(3_000);
    const before = bystander.values.get!UNIT_FIELD_HEALTH;
    assert(gluth.ai.castFor(s.map, 28374, gluth.guid, true) == ActionResult.ok);
    assert(s.hero(0).values.get!UNIT_FIELD_HEALTH == 500,
        format!"Decimate left player at %s HP"(s.hero(0).values.get!UNIT_FIELD_HEALTH));
    assert(s.hero(1).values.get!UNIT_FIELD_HEALTH == 400);
    assert(s.hero(2).values.get!UNIT_FIELD_HEALTH == 500);
    import dmangos.bytes : ByteReader;
    import dmangos.world.opcodes : Opcode;
    bool logged;
    foreach (packet; s.heroes[0].read())
        if (packet.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
        {
            auto log = ByteReader(packet.body_);
            const target = log.readPackedGuid(), caster = log.readPackedGuid();
            if (target == s.hero(0).guid && caster == gluth.guid && log.read!uint == 28375)
                logged = log.read!uint == 5500;
        }
    assert(logged, "the injured player sees 5,500 damage from Gluth's Decimate");
    assert(chow.values.get!UNIT_FIELD_HEALTH == 200,
        format!"Decimate left chow at %s HP"(chow.values.get!UNIT_FIELD_HEALTH));
    assert(bystander.values.get!UNIT_FIELD_HEALTH == before);
}

/// The same primary breath strikes the exposed player and passes over the player behind a real ice block.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : ActionResult;
    auto origin = Position(3522.386f, -5236.784f, 137.709f);
    auto s = new Scene(533, origin, [classWarrior, classMage], withTerrain: true);
    auto sap = s.summon(15989, origin);
    auto blockAt = origin;
    blockAt.x += 10;
    auto block = s.w.context.summonWildGameObject(s.map, 181247, blockAt, 22);
    assert(block !is null);
    auto sheltered = blockAt;
    sheltered.x += 5;
    s.moveHero(0, sheltered);
    auto exposed = sheltered;
    exposed.y += 12;
    s.moveHero(1, exposed);
    assert(!s.map.inLineOfSight(origin, s.hero(0).position) && s.map.inLineOfSight(origin, s.hero(1).position),
        "the block intercepts only the sheltered player's ray");
    foreach (k; 0 .. 2)
    {
        s.heroes[k].session.inWorld.godModeCheat = false;
        s.hero(k).values.set!UNIT_FIELD_MAXHEALTH(200_000);
        s.hero(k).values.set!UNIT_FIELD_HEALTH(200_000);
    }
    assert(sap.ai.castFor(s.map, 28524, sap.guid, true) == ActionResult.ok);
    assert(s.hero(0).values.get!UNIT_FIELD_HEALTH == 200_000);
    assert(s.hero(1).values.get!UNIT_FIELD_HEALTH < 200_000, "exposed player took no damage from the primary breath");
}

/// The priest uses the same spellbook command as the possession bar in the client.
private void orderControlled(Scene s, Creature controlled, uint spell, ulong target, size_t owner = 0)
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    ByteWriter command;
    command.put(controlled.guid);
    command.put(spell);
    SpellTargets(TargetFlags.unit, target).write(command);
    s.heroes[owner].write(Opcode.CMSG_PET_CAST_SPELL, command.data);
}

unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : ActionResult;
    auto s = new Scene(533, Position(3351, -3620, 261.08f), [classPriest]);
    auto widow = s.the(15953);
    auto worshipper = s.the(16506);
    auto priest = s.heroes[0].session.inWorld;
    priest.castTriggeredAt(10912, worshipper.guid);
    assert(priest.charmed is worshipper && worshipper.petData.knows(28732));
    assert(widow.ai.castFor(s.map, 28798, widow.guid, true) == ActionResult.ok);
    assert(widow.auras.find(28798) !is null);
    orderControlled(s, worshipper, 28732, worshipper.guid);
    s.run(2.seconds);
    assert(!worshipper.alive && widow.auras.find(28732) !is null && widow.auras.find(28798) is null,
        format!"sacrifice dead %s, embrace %s, frenzy %s; %s"(!worshipper.alive,
            widow.auras.find(28732) !is null, widow.auras.find(28798) !is null, s.seen()));
}

unittest
{
    if (!haveRealData())
        return;
    auto s = new Scene(533, Position(2758.3f, -3111.9f, 267.86f), [classPriest]);
    auto instructor = s.the(16061);
    auto student = s.the(16803);
    auto priest = s.heroes[0].session.inWorld;
    priest.castTriggeredAt(10912, student.guid);
    assert(priest.charmed is student && student.petData.knows(29060) && student.petData.knows(29061));
    instructor.ai.attackedBy(s.heroUnit, s.map);
    orderControlled(s, student, 29061, student.guid);
    assert(student.auras.find(29061) !is null);
    orderControlled(s, student, 29060, instructor.guid);
    assert(instructor.ai.currentVictim == student.guid);
}

/// Chains subjugates the tank and four other living raiders, leaving opponents to fight and returning control.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : ActionResult;
    import dmangos.world.relations : canAttack;
    import dmangos.world.updatefields : UNIT_FIELD_CHARMEDBY, UNIT_FIELD_FACTIONTEMPLATE;
    const at = spawnOf(533, 15990);
    auto s = new Scene(533, Position(at.x, at.y, at.z),
        [classWarrior, classWarrior, classWarrior, classWarrior, classWarrior, classWarrior]);
    s.run(1.seconds);
    auto kt = s.the(15990);
    kt.values.set!UNIT_FIELD_FLAGS(kt.values.get!UNIT_FIELD_FLAGS & ~0x0200_0000u);
    s.engage(kt);
    s.run(1.seconds);
    const tank = kt.ai.currentVictim;
    const faction = s.hero(0).values.get!UNIT_FIELD_FACTIONTEMPLATE;
    assert(tank != 0 && kt.ai.castFor(s.map, 28408, kt.guid, true) == ActionResult.ok);
    size_t[] chained;
    size_t free;
    foreach (k; 0 .. s.heroes.length)
        if (s.hero(k).auras.find(28410) !is null)
        {
            assert(s.hero(k).values.get!UNIT_FIELD_CHARMEDBY == kt.guid && !s.heroes[k].session.inWorld.inControl);
            assert(s.hero(k).auras.find(28409) !is null);
            chained ~= k;
        }
        else
        {
            assert(s.hero(k).guid != tank, "the tank escaped the Chains");
            free = k;
        }
    assert(chained.length == 5, format!"expected five chained, got %s"(chained.length));
    assert(canAttack(s.heroUnit(free).relating, s.heroUnit(chained[0]).relating, s.w.context.client));
    s.run(2.seconds);
    assert(s.heroes[chained[0]].session.inWorld.attacking == s.hero(free).guid,
        "the charmed raider did not turn on the remaining ally");
    assert(s.runUntil(() => s.hero(chained[0]).auras.find(28410) is null, 30.seconds));
    foreach (k; chained)
    {
        assert(s.hero(k).values.get!UNIT_FIELD_CHARMEDBY == 0 && s.hero(k).values.get!UNIT_FIELD_FACTIONTEMPLATE == faction);
        assert(s.heroes[k].session.inWorld.inControl && s.hero(k).auras.find(28409) is null);
        assert(!canAttack(s.heroUnit(free).relating, s.heroUnit(k).relating, s.w.context.client));
    }
}
