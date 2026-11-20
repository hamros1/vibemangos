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
    s.run(400.msecs); // its cells loaded
    s.forget();
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
        // Magmadar: Panic, Lava Bomb (one at someone without mana, one at someone with), Frenzy at 30 s with
        // its emote; back to "not started" after a wipe (ScriptDev's NOT_STARTED).
        Boss("Magmadar", 409, 11982, 1, [], [Stage(0, 35, [19408, 19411, 20474, 19451], [-1_000_001])], 0, 0, 0),
        // Gehennas: his curse, Rain of Fire, Shadow Bolt at random and at his victim; two Flamewakers.
        Boss("Gehennas", 409, 12259, 2, [flamewaker], [Stage(0, 15, [19716, 19717, 19729, 19728])]),
        // Garr: Antimagic Pulse, Magma Shackles; a Firesworn killed erupts and enrages him.
        Boss("Garr", 409, 12057, 3, [firesworn], [Stage(0, 18, [19492, 19496]),
            Stage(0, 2, [19516], null, null, [[firesworn, 19497]], killOne(firesworn))]),
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
            Stage(0, 46, [16856, 24407, 19134, 13736, 24408, 24314], [-1_309_018], [[chainedSpirit, 19], [ohgan, 1]]),
            Stage(0, 3, [23537], [-1_309_024], null, null, killOne(ohgan))], -1_309_015, 0, 2, Position.init,
            [classWarrior, classMage], null, 10, false, null, Position(-12190, -1948, 130.3f), (Scene s) {
                // He comes down from his perch when the copy says (its keepers slain), and fights all there.
                auto him = s.the(11382);
                s.signalCopy(5, 4);
                assert(s.runUntil(() => him.ai.inCombat, 60.seconds), "Mandokir does not come down to fight");
                return him;
            }),
        // Hakkar: a stack of Hakkar's Power for each priest alive (all five here); his line; list 1483401 (Cause
        // Insanity, Will of Hakkar, Corrupted Blood, Blood Siphon at 90 s). His aspects' combat conditions
        // (1005 .. 1009) are reputation and quest conditions in this world database: not asked for.
        Boss("Hakkar", 309, 14834, -1, [], [
            Stage(0, 2, null, null, null, null, (Scene s, Creature boss) {
                const aura = boss.auras.find(hakkarsPower);
                assert(aura !is null && aura.stacks == 5, format!"Hakkar's Power: %s stacks, not 5"(
                    aura is null ? 0 : aura.stacks));
            }),
            Stage(0, 90, [24327, 24178, 24328, 24324])], -1_309_020),
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
