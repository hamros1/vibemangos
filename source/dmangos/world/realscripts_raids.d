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
 * The original fight has a player take Razorgore through the Orb of Domination to break the eggs; the script lets
 * players break them by hand (its documentation says why).
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
    auto s = new Scene(469, Position(-7612, -1024, 413), [classWarrior, classMage]);
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
    s.moveHero(1, Position(-7643, -1080, 409)); // the second by Nefarian's troops (their emotes are heard 25 yards off)
    s.forget();
    const eggCount = s.objects(egg).length;
    foreach (e; s.objects(egg))
    {
        s.moveHero(0, e.position);
        s.run(400.msecs);
        s.use(e);
        s.run(400.msecs);
    }
    s.run(2.seconds);
    assert(s.ask(0) == 4, format!"the eggs broken, but the room is %s (%s eggs left of %s)"(s.ask(0), s.objects(egg).length, eggCount));
    assert(s.said(-1_469_035) && s.said(-1_469_033), "no emotes as the orb goes dark\n" ~ s.seen());
    assert(s.castBy(razorgoreEntry, 23040) && s.healthOf(razorgore) >= 100, "Razorgore not freed whole");
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
