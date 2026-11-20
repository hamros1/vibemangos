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

// ---------------------------------------------------------------------------------------------------------------
// Razorfen Kraul (47)
// ---------------------------------------------------------------------------------------------------------------

/// Razorfen Kraul: Agathelos's ward (21099) falls with the last Death's Head Ward Keeper (4625), and stays down.
unittest
{
    if (!haveRealData())
        return;
    enum uint keeper = 4625, ward = 21099;
    auto d = Dungeon.enter(47, 30);
    assert(!Dungeon.isOpen(d.objectOf(ward)), "up");
    auto first = d.spawned(keeper, 0), second = d.spawned(keeper, 1);
    d.kill(first);
    d.run(1.seconds);
    assert(!Dungeon.isOpen(d.objectOf(ward)), "up while one keeper lives");
    d.kill(second);
    d.run(1.seconds);
    assert(Dungeon.isOpen(d.objectOf(ward)), "down with the last");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(ward)), "down after a restart");
}

/**
 * Willix the Importer (4508): "Willix the Importer" (1144) taken, he says he is ready (-1047000) and walks out of the
 * kraul with the player; two Raging Agamar (4514) charge him twice on the way; at the end "Phew! Finally out here."
 * (-1047008), and the quest is complete.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint willix = 4508, agamar = 4514, quest = 1144;
    auto d = Dungeon.enter(47, 30);
    auto him = d.spawned(willix, 0, 15);
    d.acceptQuest(him, quest);
    d.run(1.seconds);
    assert(d.questStatus(quest) == imported!"dmangos.script.api".QuestProgress.incomplete, "taken");
    assert(d.heard(-1047000), "ready\n" ~ d.story);
    bool out_()
    {
        d.keepUp(him);
        d.defend(him);
        return d.heard(-1047008);
    }
    assert(d.runUntil(&out_, 400.seconds), format!"he gets out (at %s)\n%s"(him.position, d.story));
    assert(d.summoned(agamar) == 4, "the boars\n" ~ d.story);
    foreach (line; [-1047001, -1047002, -1047003, -1047004, -1047005, -1047006, -1047007])
        assert(d.heard(line), format!"line %s\n%s"(line, d.story));
    d.run(1.seconds);
    assert(d.questStatus(quest) == imported!"dmangos.script.api".QuestProgress.complete, "the quest's event");
}

/// The Snufflenose Gopher (4781), commanded (Snufflenose Command, 8283), digs up a Blueleaf Tuber (20920) near it.
unittest
{
    if (!haveRealData())
        return;
    enum uint gopher = 4781, tuber = 20920, command = 8283;
    auto d = Dungeon.enter(47, 30);
    const row = d.objectRow(tuber);
    d.goTo(Position(row.x + 5, row.y, row.z));
    size_t spawnedTubers()
    {
        size_t n;
        d.map.forEachObject((imported!"dmangos.world.map".MapObject o) {
            if (auto go = cast(GameObject) o)
                n += go.template_.entry == tuber; // one not spawned is not on the map
        });
        return n;
    }
    const before = spawnedTubers();
    auto pet = d.summon(gopher, Position(row.x + 8, row.y, row.z));
    const info = d.w.context.data.spells.spell(command);
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    d.party[0].session.inWorld.castSpell(info, SpellTargets(TargetFlags.unit, pet.guid), true, 0);
    d.run(10.seconds);
    assert(spawnedTubers() > before, format!"a tuber dug up (%s before)"(before));
}

// ---------------------------------------------------------------------------------------------------------------
// Razorfen Downs (129)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Razorfen Downs: the gong (148917) rung calls eight Tomb Fiends (7349), rung again (when they are dead) four Tomb
 * Reavers (7351), the third time Tuten'kash (7355); rung while a wave lives it calls nothing.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint gong = 148917, fiend = 7349, reaver = 7351, tutenKash = 7355;
    auto d = Dungeon.enter(129, 35);
    auto theGong = d.objectOf(gong);
    d.use(theGong);
    d.run(2.seconds);
    assert(d.summoned(fiend) == 8, "eight fiends\n" ~ d.story);
    d.use(theGong);
    d.run(2.seconds);
    assert(d.summoned(fiend) == 8 && d.summoned(reaver) == 0, "nothing while they live\n" ~ d.story);
    d.killSummons();
    d.run(2.seconds);
    d.use(theGong);
    d.run(2.seconds);
    assert(d.summoned(reaver) == 4, "four reavers\n" ~ d.story);
    d.killSummons();
    d.run(2.seconds);
    d.use(theGong);
    d.run(2.seconds);
    assert(d.summoned(tutenKash) == 1, "Tuten'kash\n" ~ d.story);
    d.killSummons();
    d.run(1.seconds);
    assert(d.saved!(imported!"dmangos.scripts.razorfendowns".RazorfenDowns).tutenKashDead, "saved");
}

/**
 * Belnistrasz (8516): "Extinguishing the Idol" (3525) taken, he runs to the idol, starts his ritual (-1129006, Idol
 * Shutdown 12774) and holds it three minutes while the quilboar come (7333, 7329, 7335, Plaguemaw 7356 last), counting
 * the minutes (-1129009 .. -1129011); done (-1129012), the quest is complete and his brazier (152097) appears.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint belnistrasz = 8516, quest = 3525, brazier = 152097, plaguemaw = 7356;
    auto d = Dungeon.enter(129, 37);
    auto him = d.spawned(belnistrasz, 0, 15);
    d.questDone(3523); // "Scourge of the Downs", before it
    d.acceptQuest(him, quest);
    d.run(1.seconds);
    assert(d.heard(-1129005), "ready\n" ~ d.story);
    bool over()
    {
        d.keepUp(him);
        d.defend(him);
        return d.heard(-1129012);
    }
    assert(d.runUntil(&over, 400.seconds), format!"the ritual done (he is at %s, alive %s)\n%s"(him.position,
        him.alive, d.story));
    assert(d.heard(-1129006) && d.cast_(12774, belnistrasz), "the ritual\n" ~ d.story);
    foreach (line; [-1129009, -1129010, -1129011])
        assert(d.heard(line), format!"line %s\n%s"(line, d.story));
    assert(d.summoned(7333) && d.summoned(plaguemaw), "the quilboar, Plaguemaw last\n" ~ d.story);
    d.run(5.seconds);
    assert(d.questStatus(quest) == imported!"dmangos.script.api".QuestProgress.complete, "the quest's event");
    assert(d.loadedObject(brazier) !is null, "his brazier");
}

// ---------------------------------------------------------------------------------------------------------------
// Blackfathom Deeps (48)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Blackfathom Deeps: a Fire of Aku'mai (21118 .. 21121) lit while Twilight Lord Kelris (4832) lives calls nothing;
 * with him dead each of the four calls its wave (snapjaws 4825, servants 4978, crustaceans 4823, softshells 4977) to
 * the shrine, and with all four waves dead the Portal of Aku'mai (21117) opens, for good.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint kelris = 4832, portal = 21117, firstFire = 21118;
    auto d = Dungeon.enter(48, 27);
    d.use(d.objectOf(firstFire));
    d.run(5.seconds);
    assert(d.summoned(4825) + d.summoned(4978) + d.summoned(4823) + d.summoned(4977) == 0,
        "nothing while Kelris lives\n" ~ d.story);
    auto lord = d.spawned(kelris, 0, 30);
    d.kill(lord);
    d.run(1.seconds);
    foreach (fire; firstFire .. firstFire + 4)
    {
        d.use(d.objectOf(fire));
        d.run(5.seconds);
    }
    assert(d.summoned(4825) == 3 && d.summoned(4978) == 2 && d.summoned(4823) == 4 && d.summoned(4977) == 10,
        "the four waves\n" ~ d.story);
    assert(!Dungeon.isOpen(d.objectOf(portal)), "shut while they live");
    d.killSummons();
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(portal)), "the portal opens");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(portal)), "open after a restart");
}

/// The Fathom Stone (177964) used calls Baron Aquanis (12876), once a copy.
unittest
{
    if (!haveRealData())
        return;
    enum uint stone = 177964, aquanis = 12876;
    auto d = Dungeon.enter(48, 27);
    auto theStone = d.objectOf(stone);
    d.use(theStone);
    d.run(2.seconds);
    assert(d.summoned(aquanis) == 1, "the baron\n" ~ d.story);
    d.use(theStone);
    d.run(2.seconds);
    assert(d.summoned(aquanis) == 1, "once\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Maraudon (349)
// ---------------------------------------------------------------------------------------------------------------

/// Maraudon: the Larva Spewer (178559) spits a Spewed Larva (13533) a minute until a player stops it (uses it).
unittest
{
    if (!haveRealData())
        return;
    enum uint spewer = 178559, larva = 13533;
    auto d = Dungeon.enter(349, 46);
    auto it = d.objectOf(spewer);
    d.run(125.seconds);
    assert(d.summoned(larva) == 2, "a larva a minute\n" ~ d.story);
    d.use(it);
    d.run(125.seconds);
    assert(d.summoned(larva) == 2, "stopped\n" ~ d.story);
}

/**
 * Noxxion (13282): Toxic Volley (21687), Uppercut (22916) and his spawns (Summon Spawns 21707: Noxxion's Spawns 13456)
 * in his fight; dead, the Corruption Spewer (178570) stops.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint noxxion = 13282, corruption = 178570;
    auto d = Dungeon.enter(349, 46);
    auto boss = d.spawned(noxxion, 0, 30);
    d.pull(boss);
    d.run(45.seconds);
    assert(d.cast_(21687, noxxion) && d.cast_(22916, noxxion), "volley and uppercut\n" ~ d.story);
    assert(d.cast_(21707, noxxion) && d.summoned(13456), "his spawns\n" ~ d.story);
    d.kill(boss);
    d.run(1.seconds);
    assert(Dungeon.isOpen(d.objectOf(corruption)), "the spewer stops");
}

// ---------------------------------------------------------------------------------------------------------------
// Scarlet Monastery (189)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Herod (3975): "Ah, I have been waiting for a real challenge!" (-1189000) and Rushing Charge (8260) as he starts,
 * Whirlwind (8989) with "Blades of Light!" (-1189001), at 30% Frenzy (8269) and his enrage line (-1189002); dead, twenty
 * Scarlet Trainees (6575) come down the hall to avenge him (-1189035).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint herod = 3975, trainee = 6575;
    auto d = Dungeon.enter(189, 40);
    auto boss = d.spawned(herod, 0, 30);
    d.pull(boss);
    d.run(30.seconds);
    assert(d.heard(-1189000) && d.cast_(8260, herod), "his charge\n" ~ d.story);
    assert(d.cast_(8989, herod) && d.heard(-1189001), "Whirlwind\n" ~ d.story);
    d.hurtTo(boss, 25);
    d.run(2.seconds);
    assert(d.cast_(8269, herod) && d.heard(-1189002), "Frenzy at 30%\n" ~ d.story);
    d.kill(boss);
    d.run(8.seconds);
    assert(d.summoned(trainee) == 20 && d.heard(-1189035), "the trainees\n" ~ d.story);
    const at = d.all(trainee)[0].position;
    d.run(10.seconds);
    const now = d.all(trainee)[0].position;
    assert((now.x - at.x) ^^ 2 + (now.y - at.y) ^^ 2 > 25, "they come down the hall");
}

/**
 * Arcanist Doan (6487): "You will not defile these mysteries!" (-1189019), Arcane Explosion (9433) and Silence (8988);
 * at half his health Arcane Bubble (9438), then Detonation (9435) with "Burn in righteous fire!" (-1189020).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint doan = 6487;
    auto d = Dungeon.enter(189, 40);
    auto boss = d.spawned(doan, 0, 30);
    d.pull(boss);
    d.run(12.seconds);
    assert(d.heard(-1189019) && d.cast_(9433, doan) && d.cast_(8988, doan), "his opening\n" ~ d.story);
    d.hurtTo(boss, 45);
    d.run(5.seconds);
    assert(d.cast_(9438, doan) && d.cast_(9435, doan) && d.heard(-1189020), "bubble and detonation\n" ~ d.story);
}

/**
 * Scarlet Commander Mograine (3976) and High Inquisitor Whitemane (3977): Mograine struck down falls, not dead; her
 * door (104600) opens and she comes ("Mograine has fallen! ...", -1189008); at half her health she puts the party to
 * sleep (Deep Sleep 9256) and raises him (Scarlet Resurrection 9232, -1189010), who rises (-1189007) and lays hands on
 * himself (9257). Both dead, the cathedral is done (saved), her door open after a restart.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint mograine = 3976, whitemane = 3977, door = 104600;
    auto d = Dungeon.enter(189, 42);
    auto him = d.spawned(mograine, 0, 30);
    d.pull(him);
    d.run(3.seconds);
    assert(d.heard(-1189005), "his aggro line\n" ~ d.story);
    d.kill(him);
    d.run(3.seconds);
    assert(him.alive, "he does not die the first time");
    assert(Dungeon.isOpen(d.objectOf(door)), "her door opens");
    assert(d.heard(-1189008), "she comes\n" ~ d.story);
    auto her = d.find(whitemane);
    assert(her !is null);
    bool fighting() { return her.ai.inCombat; }
    assert(d.runUntil(&fighting, 20.seconds), "she fights\n" ~ d.story);
    d.hurtTo(her, 45);
    bool raised() { return d.heard(-1189007); }
    assert(d.runUntil(&raised, 30.seconds), "he is raised\n" ~ d.story);
    assert(d.cast_(9256, whitemane) && d.cast_(9232, whitemane) && d.heard(-1189010), "her sleep, his raising\n" ~ d.story);
    d.run(5.seconds);
    assert(d.cast_(9257, mograine), "Lay on Hands\n" ~ d.story);
    d.kill(him);
    d.kill(her);
    d.run(2.seconds);
    assert(!him.alive && !her.alive, "both dead");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(door)), "open after a restart");
}

/**
 * Razorfen Downs and Blackfathom Deeps, a restart in the middle of an event: its summons are gone with it, so the
 * event can go on (the gong rung again calls its next wave; the Fathom Stone calls Baron Aquanis again), not wait for
 * them forever.
 */
unittest
{
    if (!haveRealData())
        return;
    {
        enum uint gong = 148917, fiend = 7349, reaver = 7351;
        auto d = Dungeon.enter(129, 35);
        d.use(d.objectOf(gong));
        d.run(2.seconds);
        assert(d.summoned(fiend) == 8);
        d.restart();
        d.forget();
        d.use(d.objectOf(gong));
        d.run(2.seconds);
        assert(d.summoned(reaver) == 4, "the next wave after a restart\n" ~ d.story);
    }
    {
        enum uint stone = 177964, aquanis = 12876;
        auto d = Dungeon.enter(48, 27);
        d.use(d.objectOf(stone));
        d.run(2.seconds);
        assert(d.summoned(aquanis) == 1);
        d.restart();
        d.forget();
        d.use(d.objectOf(stone));
        d.run(2.seconds);
        assert(d.summoned(aquanis) == 1, "the baron again after a restart (he did not die)\n" ~ d.story);
    }
}
