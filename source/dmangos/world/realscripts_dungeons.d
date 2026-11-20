/**
 * The five-player dungeons' scripts (`dmangos.scripts.*`) on the real data: each encounter in a copy of its real map,
 * its creatures the world database's spawns, fought by a character of the dungeon's level kept alive
 * (`dmangos.world.realscriptkit`), asserting what the data and the sources say the script does: its phases at their
 * health, its spells (by id, as the client is told of them), its adds, its lines (`script_texts`), its doors, the copy's
 * saved state across a restart, its reset on a wipe. Where the port and its sources disagree, the test says so.
 * Run only where `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`).
 */
module dmangos.world.realscripts_dungeons;

version (unittest):

import core.time : msecs, seconds;
import std.format : format;
import dmangos.world.creature : Creature;
import dmangos.world.gameobject : GameObject;
import dmangos.world.movement : Position;
import dmangos.world.realscriptkit;
import dmangos.world.updatefields;

// ---------------------------------------------------------------------------------------------------------------
// The Deadmines (36)
// ---------------------------------------------------------------------------------------------------------------

/// The Deadmines: Rhahk'Zor's death opens the Factory Door, and the copy remembers it across a restart.
unittest
{
    if (!haveRealData())
        return;
    enum uint rhahkZor = 644, factoryDoor = 13965;
    auto d = Dungeon.enter(36, 20);
    auto door = d.objectOf(factoryDoor);
    assert(!Dungeon.isOpen(door), "closed while he lives");
    auto boss = d.spawned(rhahkZor);
    d.pull(boss);
    d.run(2.seconds);
    d.kill(boss);
    d.run(1.seconds);
    assert(Dungeon.isOpen(d.objectOf(factoryDoor)), "his death opens it");
    assert(d.data.length, "saved");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(factoryDoor)), "open after a restart");
}

/**
 * Mr. Smite (646), as ScriptDev2's sniffed script has him: Nimble Reflexes (6433) on him; below two thirds of his health
 * Smite Stomp (6432) and "You land lubbers are tougher..." (-1036002), the reflexes gone, a run to his chest (144111),
 * two axes (2183) and Thrash (12787); no Smite Slam yet. Below one third "D'ah! Now you're making me angry!" (-1036003),
 * the great hammer (10756) with Smite's Hammer (6436), then Smite Slam (6435).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint mrSmite = 646, nimbleReflexes = 6433, thrash = 12787;
    auto d = Dungeon.enter(36, 20);
    auto boss = d.spawned(mrSmite);
    d.run(1.seconds);
    assert(boss.auras.find(nimbleReflexes) !is null, "Nimble Reflexes on him");
    d.pull(boss);
    d.run(2.seconds);
    d.hurtTo(boss, 60);
    d.run(1.seconds);
    assert(d.cast_(6432, mrSmite), "Smite Stomp at 66%\n" ~ d.story);
    assert(d.heard(-1036002), "phase two's line\n" ~ d.story);
    assert(boss.auras.find(nimbleReflexes) is null, "the reflexes gone");
    const chest = d.objectOf(144111).position;
    float distance(Position a, Position b) { return ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2) ^^ 0.5f; }
    assert(d.runUntil(() => distance(boss.position, chest) < 4, 15.seconds), format!"to his chest: he is at %s, it at %s\n%s"(boss.position, chest, d.story));
    d.run(6.seconds);
    const axe = d.w.context.virtualItem(2183).display;
    assert(boss.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(0) == axe && boss.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(1) == axe,
        "two axes");
    assert(boss.auras.find(thrash) !is null, "Thrash with them");
    d.run(15.seconds);
    assert(!d.cast_(6435, mrSmite), "no Smite Slam before the hammer\n" ~ d.story);
    d.hurtTo(boss, 30);
    d.run(1.seconds);
    assert(d.heard(-1036003), "phase three's line\n" ~ d.story);
    d.run(8.seconds);
    assert(boss.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(0) == d.w.context.virtualItem(10756).display, "the hammer");
    assert(d.cast_(6436, mrSmite), "Smite's Hammer\n" ~ d.story);
    d.run(25.seconds);
    assert(d.cast_(6435, mrSmite), "Smite Slam\n" ~ d.story);
}

/**
 * The Defias Cannon (16398) blows the Iron Clad Door (16397) open; Mr. Smite calls "You there! Check out that noise."
 * (-1036000), its guards come, and fifteen seconds on "We're under attack!..." (-1036001).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint cannon = 16398, ironCladDoor = 16397, mrSmite = 646;
    auto d = Dungeon.enter(36, 20);
    d.spawned(mrSmite);
    auto gun = d.objectOf(cannon);
    auto door = d.objectOf(ironCladDoor);
    assert(!Dungeon.isOpen(door));
    d.use(gun);
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(ironCladDoor)), "blown open");
    assert(d.heard(-1036000) && !d.heard(-1036001), "the first alarm\n" ~ d.story);
    d.run(15.seconds);
    assert(d.heard(-1036001), "the second alarm\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Shadowfang Keep (33)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Shadowfang Keep, as the keep is entered: Arugal (10000) appears before Deathstalker Vincent (4444), who falls,
 * speaks his four lines (-1033009 .. -1033012) and goes; Vincent lies dead, and stays so across a restart.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint vincent = 4444, arugalIntro = 10000;
    auto d = Dungeon.enter(33, 22);
    auto him = d.spawned(vincent, 0, 20);
    d.run(45.seconds);
    foreach (line; [-1033009, -1033010, -1033011, -1033012])
        assert(d.heard(line), format!"intro line %s\n%s"(line, d.story));
    assert(him.values.getByte!UNIT_FIELD_BYTES_1(0) == 7, "Vincent lies dead");
    assert(d.find(arugalIntro) is null || !d.find(arugalIntro).alive, "Arugal gone");
    assert(d.cast_(7741, arugalIntro) && d.cast_(7136, arugalIntro), "he comes and goes by his spells\n" ~ d.story);
    d.restart();
    d.forget();
    auto again = d.spawned(vincent, 0, 20);
    d.run(10.seconds);
    assert(again.values.getByte!UNIT_FIELD_BYTES_1(0) == 7 && !d.heard(-1033009), "no second intro");
}

/**
 * Rethilgore (3914) dead, the prisoners speak (-1033007, -1033008); Sorcerer Ashcrombe (3850), asked, leads to the
 * courtyard door (his path's twelfth point), casts Unlock (6421), and the Courtyard Door (18895) opens; he vanishes.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint rethilgore = 3914, ashcrombe = 3850, courtyardDoor = 18895;
    auto d = Dungeon.enter(33, 22);
    auto boss = d.spawned(rethilgore, 0, 25);
    d.pull(boss);
    d.run(2.seconds);
    d.kill(boss);
    d.run(2.seconds);
    assert(d.heard(-1033007) && d.heard(-1033008), "the prisoners' lines\n" ~ d.story);
    auto sorcerer = d.spawned(ashcrombe);
    d.talkTo(sorcerer);
    d.choose(sorcerer, 0);
    d.run(1.seconds);
    assert(d.heard(-1033000), "\"Follow me...\"\n" ~ d.story);
    // Walked with: the leader keeps up with him.
    bool open()
    {
        if (auto me = d.find(ashcrombe))
        {
            const at = me.position;
            if (((d.player.position.x - at.x) ^^ 2 + (d.player.position.y - at.y) ^^ 2) > 100)
            {
                d.goTo(Position(at.x + 1, at.y, at.z));
                if (Dungeon.trace) imported!"std.stdio".stderr.writefln("ash at %s, moving %s", at, me.movement);
            }
        }
        return Dungeon.isOpen(d.objectOf(courtyardDoor));
    }
    assert(d.runUntil(&open, 120.seconds), format!"the courtyard door opens: he %s at %s, in combat %s\n%s"(d.find(ashcrombe) is null ? "gone" : d.find(ashcrombe).alive ? "alive" : "dead", d.find(ashcrombe) is null ? Position.init : d.find(ashcrombe).position, d.find(ashcrombe) !is null && d.find(ashcrombe).ai.inCombat, d.story));
    assert(d.cast_(6421, ashcrombe) && d.heard(-1033001), "his spell\n" ~ d.story);
    d.run(8.seconds);
    assert(d.heard(-1033014), "he vanishes\n" ~ d.story);
    assert(d.saved!(imported!"dmangos.scripts.shadowfang".ShadowfangKeep).courtyardOpen, "saved");
}

/**
 * Fenrus the Devourer (4274) dead: Archmage Arugal appears (4275) and yells "Who dares interfere with the Sons of
 * Arugal?" (-1033013); four voidwalkers (4627) come, and the Sorcerer's Gate (18972) opens when they are dead (as it
 * is, at once, after a restart).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint fenrus = 4274, voidwalker = 4627, gate = 18972, arugal = 4275;
    auto d = Dungeon.enter(33, 24);
    auto boss = d.spawned(fenrus, 0, 25);
    d.pull(boss);
    d.run(2.seconds);
    d.kill(boss);
    d.run(15.seconds);
    assert(d.heard(-1033013), "Arugal's yell\n" ~ d.story);
    assert(d.summoned(arugal) == 1 && d.summoned(voidwalker) == 4, "Arugal and his four voidwalkers\n" ~ d.story);
    assert(!Dungeon.isOpen(d.objectOf(gate)), "the gate shut while they live");
    auto walkers = d.all(voidwalker);
    assert(walkers.length == 4);
    // One hurt: another heals it with its Dark Offering (7154).
    d.pull(walkers[0]);
    d.hurtTo(walkers[0], 40);
    d.run(15.seconds);
    assert(d.cast_(7154, voidwalker), "Dark Offering\n" ~ d.story);
    foreach (w; walkers)
        d.kill(w);
    d.run(1.seconds);
    assert(Dungeon.isOpen(d.objectOf(gate)), "open when the four are dead");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(gate)), "open after a restart");
}

/**
 * Wolf Master Nandos (3927): his pack of the hall slain, he yells "I can't believe it! You've destroyed my pack..."
 * (-1033020) and comes; his death opens Arugal's Lair (18971).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint nandos = 3927, lair = 18971;
    auto d = Dungeon.enter(33, 25);
    auto master = d.spawned(nandos, 0, 30);
    d.run(1.seconds);
    // His pack: the worgs of the upper floor (above where he comes to).
    foreach (entry; [3863u, 5058u, 3861u, 3862u])
        foreach (n; 0 .. 40)
        {
            const row = d.spawnRow(entry, n);
            if (row is null)
                break;
            if (row.z <= 151.91f)
                continue;
            auto wolf = d.spawned(entry, n, 70); // loaded from afar: Nandos, not pulled, comes by himself
            if (wolf.alive)
                d.kill(wolf);
        }
    d.run(3.seconds);
    assert(d.heard(-1033020), format!"his yell (he is in combat: %s)\n%s"(master.ai.inCombat, d.story));
    d.kill(master);
    d.run(1.seconds);
    assert(Dungeon.isOpen(d.objectOf(lair)), "the lair opens");
}

/**
 * Archmage Arugal (4275): "You, too, shall serve!" (-1033017) and Void Bolt (7588) as he starts, Thundershock (7803)
 * on his foe in melee reach, a Shadow Port (7586, 7587, 7136) within seventy seconds; a wipe and he is home, his
 * fight over.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint arugal = 4275;
    auto d = Dungeon.enter(33, 26);
    auto boss = d.spawned(arugal, 0, 40);
    d.pull(boss);
    d.run(70.seconds);
    assert(d.heard(-1033017), "his yell\n" ~ d.story);
    assert(d.cast_(7588, arugal), "Void Bolt\n" ~ d.story);
    assert(d.cast_(7803, arugal), "Thundershock\n" ~ d.story);
    assert(d.cast_(7586, arugal) || d.cast_(7587, arugal) || d.cast_(7136, arugal), "a Shadow Port\n" ~ d.story);
    d.wipe(40.seconds);
    assert(boss.alive && !boss.ai.inCombat, "home, his fight over");
}

// ---------------------------------------------------------------------------------------------------------------
// Wailing Caverns (43)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Wailing Caverns: the four Fanglords (3669, 3670, 3671, 3673) dead, the Disciple of Naralex (3678) calls "At last!
 * Naralex can be awakened!..." (broadcast_text 2101) and offers the event; walked with along his path, he stops for
 * two raptors (3636), at the circle casts Cleansing (6270) before three serpents (5755, 5048), and in Naralex's
 * chamber the awakening (6271): three moccasins (5762), seven ectoplasms (5763), Mutanus (3654); Mutanus dead,
 * Naralex (3679) wakes: "I AM AWAKE, AT LAST!" (1271), and the copy remembers it.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint disciple = 3678, ravager = 3636, viper = 5755, adder = 5048, moccasin = 5762, ectoplasm = 5763,
        mutanus = 3654;
    auto d = Dungeon.enter(43, 20);
    auto him = d.spawned(disciple, 0, 15);
    foreach (fanglord; [3669u, 3670, 3671, 3673])
    {
        auto f = d.spawned(fanglord, 0, 30);
        d.goTo(Position(him.position.x + 10, him.position.y, him.position.z)); // he says it to those near him
        d.kill(f);
    }
    d.run(2.seconds);
    assert(d.heard(2101), "his call\n" ~ d.story);
    d.talkTo(him);
    d.choose(him, 0);
    d.run(1.seconds);
    // Walked with to the end; what comes killed.
    bool awake()
    {
        d.keepUp(him);
        d.defend(him);
        return d.heard(1271);
    }
    assert(d.runUntil(&awake, 600.seconds), format!"Naralex wakes (the disciple at %s)\n%s"(him.position, d.story));
    assert(d.summoned(ravager) == 2, "two raptors\n" ~ d.story);
    assert(d.cast_(6270, disciple) && d.summoned(viper) + d.summoned(adder) == 3, "the circle\n" ~ d.story);
    assert(d.cast_(6271, disciple) && d.summoned(moccasin) == 3 && d.summoned(ectoplasm) == 7
        && d.summoned(mutanus) == 1, "the ritual\n" ~ d.story);
    foreach (line; [1256u, 1258, 1259, 1264, 1265, 1268, 1269, 1270])
        assert(d.heard(line), format!"line %s\n%s"(line, d.story));
    assert(d.saved!(imported!"dmangos.scripts.wailingcaverns".WailingCaverns).naralexAwake, "saved");
    d.run(25.seconds);
    assert(d.heard(1272) && d.heard(2103) && d.cast_(8153, disciple), "thanks, farewell, and away\n" ~ d.story);
}
