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

import core.time : minutes, msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.world.creature : Creature;
import dmangos.world.gameobject : GameObject;
import dmangos.world.movement : Position;
import dmangos.world.realscriptkit;
import dmangos.world.updatefields;

/// Stockade and Ragefire Chasm use the world database's combat AI without instance-wide events.
unittest
{
    if (!haveRealData())
        return;
    auto stockade = Dungeon.enter(34, 27);
    stockade.pull(stockade.spawned(1717));
    stockade.run(25.seconds);
    assert(stockade.cast_(421, 1717) && stockade.cast_(6742, 1717), stockade.story);

    auto ragefire = Dungeon.enter(389, 16);
    ragefire.pull(ragefire.spawned(11520));
    ragefire.run(25.seconds);
    assert(ragefire.cast_(11970, 11520) && ragefire.cast_(18072, 11520), ragefire.story);
}

/// A rogue's Disarm Trap stops suppression temporarily and killing Broodlord stops it for the lockout.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.bytes : ByteWriter;
    import dmangos.script.api : ObjectFlag;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellCastResult, TargetFlags;
    import dmangos.world.testclient : bodyOf;

    enum uint device = 179784, suppression = 22247, disarm = 1842, broodlord = 12017;
    auto d = Dungeon.enter(469, 60, 4, 2, Position(-7572.59f, -1062.57f, 449.164f));
    GameObject trap;
    d.map.forEachObject((object) {
        if (auto go = cast(GameObject) object)
            if (go.spawn.guid == 4690072)
                trap = go;
    });
    assert(trap !is null);
    const spot = Position(-7572.3f, -1062.57f, 449.164f);
    d.goTo(spot);
    d.goTo(spot, 1);
    bool suppressed(size_t member) { return d.player(member).auras.find(suppression) !is null; }
    assert(d.party[1].session.inWorld.instanceId != d.instanceId, "each player starts in a separate copy");
    assert(trap.behaviour && d.w.context.scripts.busy(trap.behaviour), "the device's pulse is scheduled");
    assert(d.map.near(trap.position, 20).length == 1, "near the device");
    assert(d.runUntil(() => suppressed(0) && suppressed(1), 6.seconds),
        format!"the same spawn pulses in both copies (%s, %s)"(suppressed(0), suppressed(1)));
    d.port(d.party[1], 469, spot, d.instanceId);
    assert(d.party[1].session.inWorld.instanceId == d.instanceId);

    assert(d.give(5060) == 1); // Thieves' Tools
    if (!d.player.knowsSpell(disarm))
        d.player.spells ~= disarm;
    ByteWriter request;
    request.put(disarm);
    request.put(cast(ushort) TargetFlags.locked);
    request.putPackedGuid(trap.guid);
    d.party[0].write(Opcode.CMSG_CAST_SPELL, request.data);
    const result = bodyOf(d.party[0].read(), Opcode.SMSG_CAST_RESULT);
    assert(d.runUntil(() => (trap.values.get!GAMEOBJECT_FLAGS & ObjectFlag.noInteract) != 0, 12.seconds),
        format!"Disarm Trap disables the device (cast result %s)"(result.length >= 6 ? cast(SpellCastResult) result[5] : SpellCastResult.ok));
    d.run(20.seconds);
    assert(!suppressed(0) && !suppressed(1), "no pulses while disarmed");
    assert(d.runUntil(() => suppressed(0) && suppressed(1), 110.seconds), "a rearmed device resumes its pulses");

    d.kill(d.spawned(broodlord, 0, 15));
    d.goTo(spot);
    d.run(20.seconds);
    assert(d.loadedObject(device) !is null && !suppressed(0) && !suppressed(1), "Lashlayer's death stops the pulses");
}

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

// ---------------------------------------------------------------------------------------------------------------
// Uldaman (70)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Archaedas (2748): woken at his altar (event 2268), he breaks free (-1070005) and fights (-1070001); every ten seconds
 * or so he wakes an earthen dwarf (Awaken Earthen Dwarf 10259: a custodian 7309 or hallshaper 7077 sheds its stone
 * skin 10255), until none is left; below two thirds his guardians (10252, -1070002), below one third his vault warders
 * (10258, -1070003). Dead, the Ancient Treasure (141979) appears.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint archaedas = 2748, custodian = 7309, hallshaper = 7077, stoned = 10255, treasure = 141979;
    auto d = Dungeon.enter(70, 45);
    auto boss = d.spawned(archaedas, 0, 25);
    d.run(1.seconds);
    d.w.context.instanceScript(d.instanceId).raise(imported!"dmangos.script.api".EventHappened(2268,
        imported!"dmangos.script.api".EntityRef(d.player.guid)));
    d.goTo(Position(boss.position.x + 5, boss.position.y, boss.position.z));
    d.run(8.seconds);
    assert(d.heard(-1070005) && d.heard(-1070001), "he breaks free\n" ~ d.story);
    assert(boss.ai.inCombat, "and fights");
    size_t stillStone()
    {
        size_t n;
        foreach (entry; [custodian, hallshaper])
            foreach (c; d.all(entry))
                n += c.auras.find(stoned) !is null;
        return n;
    }
    const stoneBefore = stillStone();
    d.run(25.seconds);
    assert(d.cast_(10259, archaedas) && stillStone() < stoneBefore, "dwarves wake\n" ~ d.story);
    d.hurtTo(boss, 60);
    d.run(2.seconds);
    assert(d.cast_(10252, archaedas) && d.heard(-1070002), "his guardians\n" ~ d.story);
    d.hurtTo(boss, 30);
    d.run(2.seconds);
    assert(d.cast_(10258, archaedas) && d.heard(-1070003), "his warders\n" ~ d.story);
    d.kill(boss);
    d.run(2.seconds);
    assert(d.loadedObject(treasure) !is null, "the treasure");
}

/**
 * Uldaman's Stone Keepers (4857): the altar's event (2228) wakes them one at a time (their stone skin 10255 gone) on
 * whoever used it; a wipe in the middle resets the whole event; the last one
 * dead, the temple doors (124367, 141869) open, for good.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : EntityRef, EventHappened;

    enum uint keeper = 4857, stoned = 10255, upper = 124367;
    auto d = Dungeon.enter(70, 45);
    d.spawned(keeper, 0, 20);
    auto keepers = d.all(keeper);
    assert(keepers.length >= 2, "the keepers");
    void altar()
    {
        d.w.context.instanceScript(d.instanceId).raise(EventHappened(2228, EntityRef(d.player.guid)));
    }
    Creature awake()
    {
        foreach (k; d.all(keeper))
            if (k.auras.find(stoned) is null)
                return k;
        return null;
    }
    altar();
    d.run(7.seconds);
    auto first = awake();
    assert(first !is null && first.ai.inCombat, "the first wakes and fights");
    d.kill(first);
    const firstGuid = first.guid;
    d.run(7.seconds);
    assert(awake() !is null, "the next wakes");
    d.wipe(30.seconds);
    d.revive();
    d.run(5.seconds);
    assert(awake() is null, "after the wipe they are stone again");
    assert(d.all(keeper).length == keepers.length && d.all(keeper).canFind!(k => k.guid == firstGuid),
        "the keeper killed before the wipe is back");
    altar();
    bool open()
    {
        if (auto k = awake())
            d.kill(k);
        return Dungeon.isOpen(d.objectOf(upper));
    }
    assert(d.runUntil(&open, 200.seconds), "the event done again, the doors open\n" ~ d.story);
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(upper)), "open after a restart");
}

/**
 * Uldaman restarted in the middle of its events: the Stone Keepers' waking stops (those left stand in stone, nobody
 * wakes them), and the altar used again does it all; Archaedas, woken, sleeps again after the restart and his altar
 * wakes him anew.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.script.api : EntityRef, EventHappened;

    enum uint keeper = 4857, stoned = 10255, upper = 124367, archaedas = 2748;
    auto d = Dungeon.enter(70, 45);
    d.spawned(keeper, 0, 20);
    void altar(uint event)
    {
        d.w.context.instanceScript(d.instanceId).raise(EventHappened(event, EntityRef(d.player.guid)));
    }
    Creature awake()
    {
        foreach (k; d.all(keeper))
            if (k.auras.find(stoned) is null)
                return k;
        return null;
    }
    altar(2228);
    d.run(7.seconds);
    auto first = awake();
    assert(first !is null);
    d.kill(first);
    d.run(2.seconds);
    d.restart();
    d.spawned(keeper, 0, 20);
    d.run(15.seconds);
    assert(awake() is null, "nobody wakes them after the restart");
    altar(2228);
    assert(d.all(keeper).canFind!(k => k.guid == first.guid), "restarting the event revives the missing keeper");
    bool open()
    {
        if (auto k = awake())
            d.kill(k);
        return Dungeon.isOpen(d.objectOf(upper));
    }
    assert(d.runUntil(&open, 200.seconds), "the event done again after the restart\n" ~ d.story);

    auto boss = d.spawned(archaedas, 0, 25);
    altar(2268);
    d.goTo(Position(boss.position.x + 5, boss.position.y, boss.position.z));
    d.run(8.seconds);
    assert(boss.ai.inCombat, "Archaedas fights");
    d.goTo(Position(boss.position.x + 150, boss.position.y, boss.position.z));
    d.restart();
    d.forget();
    boss = d.spawned(archaedas, 0, 25);
    d.run(2.seconds);
    assert(!boss.ai.inCombat && !d.heard(-1070001), "asleep after the restart");
    altar(2268);
    d.goTo(Position(boss.position.x + 5, boss.position.y, boss.position.z));
    d.run(8.seconds);
    assert(d.heard(-1070005) && boss.ai.inCombat, "his altar wakes him again\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Zul'Farrak (209)
// ---------------------------------------------------------------------------------------------------------------

/// Zul'Farrak: the Gong of Zul'Farrak (141832) calls Gahz'rilla (7273), once.
unittest
{
    if (!haveRealData())
        return;
    enum uint gong = 141832, gahzrilla = 7273;
    auto d = Dungeon.enter(209, 45);
    auto it = d.objectOf(gong);
    d.use(it);
    d.run(15.seconds);
    assert(d.summoned(gahzrilla) == 1, "Gahz'rilla\n" ~ d.story);
    d.use(it);
    d.run(15.seconds);
    assert(d.summoned(gahzrilla) == 1, "once\n" ~ d.story);
}

/**
 * The pyramid: the prisoners freed (event 2609, the cages unlocked), the Sandfury come, and run up the steps to
 * Sergeant Bly (7604) a few at a time; Nekrum (7796) and Sezz'ziz (7275) come last, and dead, the End Door (146084) opens, for good.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint bly = 7604, nekrum = 7796, sezzziz = 7275, endDoor = 146084;
    auto d = Dungeon.enter(209, 46);
    auto sergeant = d.spawned(bly, 0, 10);
    d.event(2609);
    d.run(60.seconds);
    // Trolls near Bly: sent up the steps.
    size_t near;
    d.map.forEachObject((imported!"dmangos.world.map".MapObject o) {
        if (auto c = cast(Creature) o)
            if ([7787u, 7788, 7789, 8876, 8877].canFind(c.template_.entry) && c.alive)
            {
                const p = c.position, b = sergeant.position;
                near += (p.x - b.x) ^^ 2 + (p.y - b.y) ^^ 2 < 15 ^^ 2;
            }
    });
    assert(near > 0, "the Sandfury come up to Bly\n" ~ d.story);
    assert(!Dungeon.isOpen(d.objectOf(endDoor)), "shut");
    // Nekrum and Sezz'ziz come after them (the event's database script, at 250 s).
    d.run(200.seconds);
    foreach (entry; [nekrum, sezzziz])
    {
        auto c = d.find(entry);
        assert(c !is null, format!"%s came"(entry));
        d.kill(c);
    }
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(endDoor)), "the End Door opens");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(endDoor)), "open after a restart");
}

/**
 * Witch Doctor Zum'rah (7271): come near, he turns hostile ("Sands consume you!", -1209000) and fights
 * (-1209001); his Shadow Bolt (12739), and the graves give up their dead (zombies 7286).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint zumrah = 7271, zombie = 7286;
    auto d = Dungeon.enter(209, 46);
    auto boss = d.spawned(zumrah, 0, 30);
    d.goTo(Position(boss.position.x + 6, boss.position.y, boss.position.z));
    d.run(30.seconds);
    assert(d.heard(-1209000), "he turns\n" ~ d.story);
    assert(boss.ai.inCombat && d.heard(-1209001), "and fights\n" ~ d.story);
    assert(d.cast_(12739, zumrah), "Shadow Bolt\n" ~ d.story);
    // ("Come to me, my children!", -1209003, is said three times in ten: not asserted.)
    assert(d.runUntil(() => d.summoned(zombie) > 0, 60.seconds), "the dead rise\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Gnomeregan (90)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Mekgineer Thermaplugg (7800): his yell (-1090024) as he starts, the Final Chamber (142207) shut behind the party,
 * the third gnome face spitting walking bombs (7915) until its button (142216) is pressed; Knock Away (10101) and
 * Activate Bomb (11511); below half "Usurpers! Gnomeregan is mine!" (-1090025); dead, the chamber opens.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint thermaplugg = 7800, bomb = 7915, chamber = 142207, button3 = 142216;
    auto d = Dungeon.enter(90, 33);
    auto boss = d.spawned(thermaplugg, 0, 30);
    d.pull(boss);
    d.run(8.seconds);
    assert(d.heard(-1090024), "his yell\n" ~ d.story);
    assert(!Dungeon.isOpen(d.objectOf(chamber)), "the chamber shut");
    assert(d.summoned(bomb) > 0, "the third face's bombs\n" ~ d.story);
    d.run(20.seconds);
    assert(d.cast_(10101, thermaplugg) && d.cast_(11511, thermaplugg), "Knock Away, Activate Bomb\n" ~ d.story);
    d.use(d.objectOf(button3));
    d.pull(boss);
    d.hurtTo(boss, 45);
    d.run(2.seconds);
    assert(d.heard(-1090025), "below half\n" ~ d.story);
    d.kill(boss);
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(chamber)), "open when he is dead");
}

/// Thermaplugg's fight cut by a restart: his faces spit no bombs at nobody afterwards, and the chamber is not shut.
unittest
{
    if (!haveRealData())
        return;
    enum uint thermaplugg = 7800, bomb = 7915, chamber = 142207;
    auto d = Dungeon.enter(90, 33);
    auto boss = d.spawned(thermaplugg, 0, 30);
    d.pull(boss);
    d.run(8.seconds);
    assert(d.summoned(bomb) > 0);
    d.goTo(Position(boss.position.x + 80, boss.position.y, boss.position.z));
    d.restart();
    d.forget();
    d.run(40.seconds);
    assert(d.summoned(bomb) == 0, "no bombs after the restart\n" ~ d.story);
    assert(Dungeon.isOpen(d.objectOf(chamber)), "the chamber open");
}

/**
 * Blastmaster Emi Shortfuse (7998): asked to begin (-1090000), she goes to the cave-ins, the troggs dig through
 * (Caverndeep Ambushers 6207) while she sets her charges, and she blows both tunnels shut (12159, 12158; -1090012,
 * -1090021); Grubbis (7361) comes out of the second (-1090023), and his death brings the red rockets (103820).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint emi = 7998, ambusher = 6207, grubbis = 7361, rocket = 103820;
    auto d = Dungeon.enter(90, 32);
    auto her = d.spawned(emi, 0, 15);
    d.talkTo(her);
    d.choose(her, 0);
    d.run(1.seconds);
    assert(d.heard(-1090000), "she begins\n" ~ d.story);
    bool grubbisDead()
    {
        d.keepUp(her);
        d.defend(her);
        d.killSummons([ambusher, 6206u]);
        if (auto g = d.find(grubbis))
            if (g.alive && d.heard(-1090023))
                d.kill(g);
        return d.summoned(grubbis) && d.find(grubbis) !is null && !d.find(grubbis).alive;
    }
    assert(d.runUntil(&grubbisDead, 600.seconds), format!"Grubbis comes and dies (she %s at %s)\n%s"(her.alive
        ? "alive" : "dead", her.position, d.story));
    d.run(25.seconds);
    assert(d.summoned(ambusher) > 0, "the troggs\n" ~ d.story);
    assert(d.heard(-1090012) && d.heard(-1090021), "both tunnels blown\n" ~ d.story);
    assert(d.cast_(12159, emi) && d.cast_(12158, emi), "her explosions\n" ~ d.story);
    assert(her.alive && d.heard(-1090022), "she lives to say it is done\n" ~ d.story);
    assert(d.loadedObject(rocket) !is null, "the red rockets");
}

// ---------------------------------------------------------------------------------------------------------------
// The Sunken Temple (109)
// ---------------------------------------------------------------------------------------------------------------

/**
 * The Sunken Temple: the six Atal'ai Statues (148830 .. 148835) used in their order light up and call Atal'alarion
 * (8580), the Idol of Hakkar (148838) with him; used out of order, a statue does nothing for the event.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint atalarion = 8580, idol = 148838;
    static immutable uint[6] statues = [148830, 148831, 148832, 148833, 148834, 148835];
    auto d = Dungeon.enter(109, 50);
    d.use(d.objectOf(statues[1]));
    d.run(2.seconds);
    d.use(d.objectOf(statues[0]));
    d.run(2.seconds);
    assert(d.saved!(imported!"dmangos.scripts.sunkentemple".SunkenTemple).statuesDone == 1, "the out of order one did not count");
    foreach (statue; statues[1 .. $])
    {
        d.use(d.objectOf(statue));
        d.run(2.seconds);
    }
    assert(d.summoned(atalarion) == 1, "Atal'alarion\n" ~ d.story);
    assert(d.loadedObject(idol) !is null, "the idol");
}

/// The statues half done when the server restarts: their order starts again from the first (their lights went).
unittest
{
    if (!haveRealData())
        return;
    enum uint atalarion = 8580;
    static immutable uint[6] statues = [148830, 148831, 148832, 148833, 148834, 148835];
    auto d = Dungeon.enter(109, 50);
    foreach (statue; statues[0 .. 3])
    {
        d.use(d.objectOf(statue));
        d.run(2.seconds);
    }
    d.restart();
    foreach (statue; statues[3 .. $])
    {
        d.use(d.objectOf(statue));
        d.run(2.seconds);
    }
    assert(d.summoned(atalarion) == 0, "the last three alone do not call him after the restart\n" ~ d.story);
    foreach (statue; statues)
    {
        d.use(d.objectOf(statue));
        d.run(2.seconds);
    }
    assert(d.summoned(atalarion) == 1, "Atal'alarion after the restart\n" ~ d.story);
}

/**
 * The Avatar of Hakkar: the Egg of Hakkar's event (8502) calls the Shade of Hakkar (8440), shuts the doors (149432,
 * 149433) and sends minions (8437) and a bloodkeeper (8438) out of the circles; each Eternal Flame (148418 ..)
 * doused with the Hakkari Blood (10460) brings a line (-1109006 ..) and, some seconds later, a Nightmare Suppressor
 * (8497) through a door, who walks its path to the Shade and casts Suppression (12623) on it: left alive twenty
 * seconds, the ritual fails (-1109015, the Shade gone, the doors open). Begun again, with each suppressor killed in
 * time, the fourth flame brings the Avatar (8443); dead, the doors open. A restart in the middle of the ritual ends it,
 * and the egg begins it again.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint shade = 8440, avatar = 8443, suppressor = 8497, hakkariBlood = 10460, door1 = 149432;
    static immutable uint[4] flames = [148418, 148419, 148420, 148421];
    auto d = Dungeon.enter(109, 55);
    d.give(hakkariBlood, 10);
    d.goTo(Position(-466.8673f, 262.31204f, -90.7441f));
    d.event(8502);
    d.run(5.seconds);
    assert(d.summoned(shade) == 1, "the Shade\n" ~ d.story);
    assert(!Dungeon.isOpen(d.objectOf(door1)), "the doors shut");
    assert(d.summoned(8437) >= 8 && d.summoned(8438) >= 1, "the first wave\n" ~ d.story);
    d.killSummons([8437u, 8438]);
    d.use(d.objectOf(flames[0]));
    d.run(1.seconds);
    assert(d.heard(-1109006), "the first flame\n" ~ d.story);
    // Its suppressor left to suppress the Shade.
    bool suppressed() { d.killSummons([8437u, 8438]); return d.cast_(12623, suppressor); }
    assert(d.runUntil(&suppressed, 90.seconds), "a suppressor reaches the Shade\n" ~ d.story);
    bool failed() { d.killSummons([8437u, 8438]); return d.heard(-1109015); }
    assert(d.runUntil(&failed, 25.seconds), "twenty seconds of suppression: the ritual fails\n" ~ d.story);
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(door1)), "the doors open again");
    d.killSummons();

    // Begun again: each suppressor killed as it comes.
    d.forget();
    d.goTo(Position(-466.8673f, 262.31204f, -90.7441f));
    d.event(8502);
    d.run(5.seconds);
    assert(d.summoned(shade) == 1, "the Shade again\n" ~ d.story);
    foreach (flame; flames)
    {
        d.killSummons([8437u, 8438]);
        d.use(d.objectOf(flame));
        d.run(1.seconds);
        if (flame != flames[$ - 1])
        {
            bool came() { d.killSummons([8437u, 8438]); return d.find(suppressor) !is null && d.find(suppressor).alive; }
            assert(d.runUntil(&came, 60.seconds), "a suppressor\n" ~ d.story);
            d.run(3.seconds);
            d.killSummons([suppressor]);
        }
    }
    d.run(2.seconds);
    assert(!d.heard(-1109015), "not failed\n" ~ d.story);
    assert(d.summoned(avatar) == 1, "the Avatar\n" ~ d.story);
    d.kill(d.find(avatar));
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(door1)), "his death opens the doors");
}

/// The Avatar's ritual cut by a restart: the egg begins it again.
unittest
{
    if (!haveRealData())
        return;
    enum uint shade = 8440;
    auto d = Dungeon.enter(109, 55);
    d.goTo(Position(-466.8673f, 262.31204f, -90.7441f));
    d.event(8502);
    d.run(5.seconds);
    assert(d.summoned(shade) == 1);
    d.killSummons([8437u, 8438]); // nothing fights (what would give up its fight as the party leaves)
    d.run(1.seconds);
    d.restart();
    d.forget();
    d.run(10.seconds);
    assert(d.summoned(8437) == 0, "no waves after the restart\n" ~ d.story);
    d.event(8502);
    d.run(5.seconds);
    assert(d.summoned(shade) == 1, "the Shade comes again\n" ~ d.story);
}

/**
 * Malfurion Stormrage (15362): one who has done "The Charge of the Dragonflights" (8555) and not "Eranikus, Tyrant of
 * the Dream" (8733) comes before the Shade of Eranikus (area trigger 4016): he appears (-1109000) and speaks his four
 * lines (-1109001 .. -1109004), once a copy; after a restart (he went with it) he comes again.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint malfurion = 15362;
    auto d = Dungeon.enter(109, 55);
    d.questDone(8555);
    d.trigger(4016);
    d.run(50.seconds);
    assert(d.summoned(malfurion) == 1, "he comes\n" ~ d.story);
    foreach (line; [-1109000, -1109001, -1109002, -1109003, -1109004])
        assert(d.heard(line), format!"line %s\n%s"(line, d.story));
    d.trigger(4016);
    d.run(2.seconds);
    assert(d.summoned(malfurion) == 1, "once\n" ~ d.story);
    d.restart();
    d.forget();
    d.questDone(8555);
    d.trigger(4016);
    d.run(5.seconds);
    assert(d.summoned(malfurion) == 1, "again after the restart\n" ~ d.story);
}

/**
 * Jammal'an's barrier (149431) falls with the last of his six protectors (5712 .. 5717): he (5710) may be fought then;
 * his death lets the Shade of Eranikus (5709) be fought.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.defines : UnitFlags;

    enum uint jammalan = 5710, eranikus = 5709, barrier = 149431;
    auto d = Dungeon.enter(109, 52);
    foreach (protector; 5712u .. 5718u)
    {
        auto p = d.spawned(protector, 0, 40);
        d.kill(p);
    }
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(barrier)), "the barrier falls");
    auto prophet = d.spawned(jammalan, 0, 40);
    assert(!(prophet.values.get!UNIT_FIELD_FLAGS & UnitFlags.immuneToPlayer), "he may be fought");
    d.kill(prophet);
    d.run(2.seconds);
    auto shade = d.spawned(eranikus, 0, 40);
    assert(!(shade.values.get!UNIT_FIELD_FLAGS & UnitFlags.immuneToPlayer), "and then the shade");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(barrier)), "down after a restart");
}

// ---------------------------------------------------------------------------------------------------------------
// Scholomance (289)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Scholomance: the six masters of the rooms (Malicia 10505, Theolen 11261, Polkelt 10901, Ravenian 10507, Alexei
 * 10504, Illucia 10502) dead, Darkmaster Gandling (1853) comes (-1289000); in his fight his Shadow Portal (17950) sends
 * someone off to a room. Rattlegore (11622) dead, the entrance room fills again.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint gandling = 1853, rattlegore = 11622;
    auto d = Dungeon.enter(289, 60);
    foreach (master; [10505u, 11261, 10901, 10507, 10504, 10502])
    {
        auto m = d.spawned(master, 0, 40);
        d.kill(m);
        d.run(1.seconds);
    }
    d.goTo(Position(180.771f, -5.4286f, 75.5702f));
    d.run(3.seconds);
    assert(d.summoned(gandling) == 1 || d.find(gandling) !is null, "Gandling comes\n" ~ d.story);
    auto him = d.find(gandling);
    assert(him !is null && him.alive);
    d.pull(him);
    const before = d.player.position;
    bool ported() { return d.cast_(17950, gandling); }
    assert(d.runUntil(&ported, 60.seconds), "his Shadow Portal\n" ~ d.story);
    d.run(3.seconds);
    const after = d.player.position;
    assert((after.x - before.x) ^^ 2 + (after.y - before.y) ^^ 2 > 100, "sent off to a room");
    d.forget();
    auto bones = d.spawned(rattlegore, 0, 40);
    d.kill(bones);
    d.run(3.seconds);
    assert(d.summons.length >= 17, "the entrance room fills again\n" ~ d.story);
}

/// Jandice Barov (10503): her Curse of Blood (16098), and her illusions (Summon Illusions 17773: 11439) come in her fight.
unittest
{
    if (!haveRealData())
        return;
    enum uint jandice = 10503;
    auto d = Dungeon.enter(289, 60);
    auto her = d.spawned(jandice, 0, 30);
    d.pull(her);
    d.run(30.seconds);
    assert(d.cast_(16098, jandice), "Curse of Blood\n" ~ d.story);
    assert(d.cast_(17773, jandice) && d.summoned(11439) > 0, "her illusions\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Stratholme (329)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Stratholme's ziggurats, fought one after another as players go: each master dead (the Baroness 10436, Nerub'enkan
 * 10437, Maleki 10438) opens his ziggurat; the acolytes (10399) around it dead, its crystal (10415) dies, and an
 * acolyte announces it (-1329004 .. -1329006); the three crystals dead, the Baron (-1329007) opens the square
 * (the gauntlet's and slaughter square's ports, 175374, 175373).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint acolyte = 10399, crystal = 10415, port = 175374;
    static immutable uint[3] masters = [10436, 10437, 10438];
    static immutable uint[3] doors = [175380, 175379, 175381];
    auto d = Dungeon.enter(329, 60);
    foreach (i, master; masters)
    {
        auto m = d.spawned(master, 0, 30);
        d.kill(m);
        d.run(2.seconds);
        assert(Dungeon.isOpen(d.objectOf(doors[i])), format!"ziggurat %s opens"(i));
        // Its acolytes, around its door.
        const door = d.objectRow(doors[i]);
        foreach (a; d.all(acolyte))
            if ((a.position.x - door.x) ^^ 2 + (a.position.y - door.y) ^^ 2 < 35 ^^ 2)
                d.kill(a);
        d.run(2.seconds);
        assert(d.heard(-1329004 - cast(int) i), format!"ziggurat %s's crystal dies\n%s"(i, d.story));
    }
    assert(d.heard(-1329007), "the Baron's yell\n" ~ d.story);
    assert(Dungeon.isOpen(d.objectOf(port)), "the square opens");
}

/**
 * The Baron's run: the Gauntlet's gate (175357) opened starts it (-1329009); the Baron warns at ten and five minutes
 * left (-1329010, -1329011), and at forty-five minutes Ysida dies (-1329012).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint gate = 175357;
    auto d = Dungeon.enter(329, 60);
    d.spawned(10440, 0, 60); // the Baron, loaded
    d.use(d.objectOf(gate));
    d.run(3.seconds);
    assert(d.heard(-1329009), "the run starts\n" ~ d.story);
    // Near him, his cell loaded (his warnings need him there: one whose cell is not loaded says nothing).
    d.spawned(10440, 0, 60);
    d.run(35.minutes + 5.seconds, 1.seconds);
    assert(d.heard(-1329010), "ten minutes left, the Baron's warning\n" ~ d.story);
    d.run(5.minutes, 1.seconds);
    assert(d.heard(-1329011), "five minutes left\n" ~ d.story);
    d.run(5.minutes + 15.seconds, 1.seconds);
    assert(d.heard(-1329012), "the time is up: Ysida dies\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Blackrock Depths (230)
// ---------------------------------------------------------------------------------------------------------------

/**
 * The Ring of Law (area trigger 1526): High Justice Grimstone (10096) comes and sentences the party; two waves of one
 * kind of beast come through the east gate, then (both dead) a champion through the north gate; all dead, the ring is
 * won, its gates open (saved).
 */
unittest
{
    import dmangos.scripts.blackrockdepths : BlackrockDepths, Fight;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    if (!haveRealData())
        return;
    enum uint grimstone = 10096;
    static immutable uint[6] beasts = [8925, 8926, 8927, 8928, 8933, 8932];
    static immutable uint[6] champions = [9027, 9028, 9029, 9030, 9031, 9032];
    auto d = Dungeon.enter(230, 55);
    d.trigger(1526);
    assert(d.runUntil(() => d.saved!BlackrockDepths.ringStage == 4, 18.seconds), d.story);
    assert(d.summoned(grimstone) == 1, "Grimstone\n" ~ d.story);
    uint kinds;
    foreach (b; beasts)
        kinds += d.summoned(b) > 0;
    assert(kinds == 1, "beasts of one kind\n" ~ d.story);
    const count = d.killSummons(beasts[]);
    d.run(50.msecs);
    auto atBreak = d.saved!BlackrockDepths;
    assert(count && atBreak.ringMobs.allDead && atBreak.ringStage == 4, d.story);
    const delay = atBreak.steps.remaining(BlackrockDepths.Step.ring);
    assert(delay > 4_000 && delay <= 5_000);
    d.restartAfterCrash();
    const resumed = d.saved!BlackrockDepths;
    const remaining = resumed.steps.remaining(BlackrockDepths.Step.ring);
    assert(resumed.ringStage == 4 && resumed.ringBeast == atBreak.ringBeast && resumed.ringMobs.allDead);
    assert(remaining > 0 && delay - remaining >= 0 && delay - remaining <= 750);
    assert(d.all(BlackrockDepths.beasts[resumed.ringBeast]).length == 0, "the defeated wave stays gone");
    assert(d.all(grimstone).length == 1, "the announcer was restored once");
    d.run((remaining - 100).msecs);
    assert(d.saved!BlackrockDepths.ringStage == 4, "no early wave");
    d.run(150.msecs);
    assert(d.saved!BlackrockDepths.ringStage == 5);
    assert(d.saved!BlackrockDepths.ringMobs.alive == count);
    auto secondWave = d.all(BlackrockDepths.beasts[resumed.ringBeast]);
    assert(secondWave.length == count);
    const defeated = secondWave[0].guid;
    const wounded = secondWave[1].guid;
    d.hit(secondWave[1], secondWave[1].values.get!UNIT_FIELD_HEALTH / 3);
    const health = secondWave[1].values.get!UNIT_FIELD_HEALTH;
    d.kill(secondWave[0]); // the death checkpoints the remaining wave, including the wounded beast
    assert(d.saved!BlackrockDepths.ringMobs.alive == count - 1);
    d.restartAfterCrash();
    assert(d.saved!BlackrockDepths.ringStage == 5);
    assert(d.map.findObject(defeated) is null, "the dead beast did not return");
    assert(d.map.creatureAt(wounded).values.get!UNIT_FIELD_HEALTH == health, "the same wounded beast resumed");
    assert(d.all(BlackrockDepths.beasts[resumed.ringBeast]).length == count - 1);
    bool champion()
    {
        foreach (b; beasts)
            if (d.summoned(b))
                d.killSummons([b]);
        foreach (c; champions)
            if (d.summoned(c))
                return true;
        return false;
    }
    assert(d.runUntil(&champion, 60.seconds), "a champion\n" ~ d.story);
    d.killSummons(champions[]);
    d.run(10.seconds);
    assert(d.saved!BlackrockDepths.ring == Fight.done, "the ring is won");
}

/**
 * The Tomb of the Seven: Doom'rel (9039) challenged (his gossip), the dwarves (9034 .. 9038, 9040) turn on the party one
 * after another, Doom'rel last; all dead, the copy remembers the tomb done.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.scripts.blackrockdepths : BlackrockDepths, Fight;

    enum uint doomrel = 9039;
    auto d = Dungeon.enter(230, 55);
    auto him = d.spawned(doomrel, 0, 15);
    d.talkTo(him);
    d.choose(him, 0);
    d.run(3.seconds);
    bool done()
    {
        foreach (dwarf; BlackrockDepths.tombDwarves)
            foreach (c; d.all(dwarf))
                if (c.ai.inCombat)
                    d.kill(c);
        return d.saved!BlackrockDepths.tomb == Fight.done;
    }
    assert(d.runUntil(&done, 400.seconds), format!"the seven fall (round %s, tomb %s)\n%s"(d.saved!BlackrockDepths.dwarfRound, d.saved!BlackrockDepths.tomb, d.story));
}

// ---------------------------------------------------------------------------------------------------------------
// Blackrock Spire (229)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Pyroguard Emberseer (9816): his altar's event (4884) frees the Blackhand Incarcerators (10316) to be fought; they dead,
 * he grows to his full strength and fights; dead, his way out (175153) opens and the copy remembers.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint emberseer = 9816, incarcerator = 10316, outDoor = 175153;
    auto d = Dungeon.enter(229, 60);
    auto boss = d.spawned(emberseer, 0, 15);
    d.event(4884);
    d.run(2.seconds);
    auto guards = d.all(incarcerator);
    assert(guards.length > 0, "his incarcerators");
    foreach (g; guards)
    {
        d.pull(g);
        d.kill(g);
    }
    bool fighting() { return boss.ai.inCombat; }
    assert(d.runUntil(&fighting, 60.seconds), "he breaks free and fights\n" ~ d.story);
    d.kill(boss);
    d.run(2.seconds);
    assert(Dungeon.isOpen(d.objectOf(outDoor)), "his way out opens");
    d.restart();
    assert(Dungeon.isOpen(d.objectOf(outDoor)), "open after a restart");
}

/**
 * Overlord Wyrmthalak (9568): below half his health (51%) he calls two guards (9583, 9268, 9216) to his side.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint wyrmthalak = 9568;
    auto d = Dungeon.enter(229, 60);
    auto boss = d.spawned(wyrmthalak, 0, 30);
    d.pull(boss);
    d.hurtTo(boss, 45);
    d.run(3.seconds);
    assert(d.summoned(9583) + d.summoned(9268) + d.summoned(9216) >= 2, "his guards\n" ~ d.story);
}

// ---------------------------------------------------------------------------------------------------------------
// Dire Maul (429)
// ---------------------------------------------------------------------------------------------------------------

/**
 * Dire Maul North: Mizzle arrives even if Cho'Rush is dead. The coronation enables the tribute
 * dialogue, and the chest gives only the loot tiers unlocked by survivors.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.loothandlers : ClientLootSlot;
    import dmangos.world.motion : WaypointMovement;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.spellcast : SpellCastResult, TargetFlags;
    import dmangos.world.testclient : bodyOf;

    enum uint king = 11501, mizzle = 14353, tribute = 179564, coronation = 22799, opening = 3365;
    static immutable uint[6] bosses = [14324, 14326, 14321, 14323, 14325, 14322];
    foreach (run, kills; [0, 1, 6, 0])
    {
        const testExpiry = run == 3;
        auto d = Dungeon.enter(429, 60);
        foreach (entry; bosses[0 .. kills])
            d.kill(d.spawned(entry, 0, 25));
        d.kill(d.spawned(king, 0, 25));
        assert(d.summoned(mizzle) == 1, "Mizzle comes\n" ~ d.story);
        assert(!(d.find(mizzle).values.get!UNIT_NPC_FLAGS & 1), "the coronation opens at the throne");
        const heraldGuid = d.find(mizzle).guid;
        if (run == 0)
        {
            bool onTheWay()
            {
                auto herald = d.find(mizzle);
                d.keepUp(herald);
                auto route = cast(WaypointMovement) herald.generator;
                return route !is null && route.lastWaypoint == 2 && herald.position.x > 730;
            }
            assert(d.runUntil(&onTheWay, 45.seconds), "Mizzle starts his route");
            d.handoff();
            auto arrived = d.find(mizzle);
            assert(arrived !is null && arrived.guid == heraldGuid, "the same herald arrived");
            auto route = cast(WaypointMovement) arrived.generator;
            assert(route !is null && route.lastWaypoint == 2, "the new node resumes Mizzle's route");
        }
        bool atThrone()
        {
            auto herald = d.find(mizzle);
            d.keepUp(herald);
            return herald !is null && (herald.values.get!UNIT_NPC_FLAGS & 1) && herald.position.x > 816;
        }
        assert(d.runUntil(&atThrone, 90.seconds), "Mizzle reaches the throne\n" ~ d.story);
        if (run == 0)
        {
            d.handoff();
            auto waiting = d.find(mizzle);
            assert(waiting !is null && waiting.guid == heraldGuid && d.summoned(mizzle) == 1, "only one herald");
            auto route = cast(WaypointMovement) waiting.generator;
            assert(route !is null && route.paused && route.lastWaypoint == 7, "he still waits for the tribute dialogue");
        }
        auto herald = d.find(mizzle);
        assert(d.loadedObject(tribute) is null, "tribute awaits Mizzle's dialogue");
        d.talkTo(herald);
        d.choose(herald, 0); // coronation
        if (testExpiry)
        {
            d.handoff(); // the cast still needs its player on the receiving node
            herald = d.find(mizzle);
        }
        d.run(1.seconds);
        assert(d.player.auras.find(coronation) !is null, "King of the Gordok");
        if (testExpiry)
            d.talkTo(herald);
        else
            d.choose(herald, 0); // return to the initial menu
        d.choose(herald, 0); // ask about tribute
        d.choose(herald, 0); // ask to see it
        if (run == 0)
        {
            assert(d.w.context.runningScripts > 0 && d.loadedObject(tribute) is null, "the tribute request is queued");
            d.handoff();
            assert(!(d.find(mizzle).values.get!UNIT_NPC_FLAGS & 1), "Mizzle removed gossip while preparing the chest");
            d.handoff(); // after disabling gossip, before the delayed step enables it again
            herald = d.find(mizzle);
            assert(d.runUntil(() => (herald.values.get!UNIT_NPC_FLAGS & 1) != 0, 800.msecs),
                "the remaining delay survives without replaying completed steps");
        }
        assert(d.runUntil(() => d.loadedObject(tribute) !is null, 5.seconds),
            "Mizzle completes the tribute request\n" ~ d.story);
        size_t chests;
        d.map.forEachObject((object) {
            if (auto go = cast(GameObject) object)
                chests += go.template_.entry == tribute;
        });
        assert(chests == 1, "Mizzle produces exactly one tribute chest");
        auto chest = d.loadedObject(tribute);
        if (testExpiry)
        {
            const chestGuid = chest.guid;
            enum uint ritualCircle = 179668, lifetime = 3600;
            const deadline = d.w.context.unixTime + lifetime; // the unopened chest's database-script lifetime
            auto circle = d.w.context.summonWildGameObject(d.map, ritualCircle, chest.position, lifetime + 2);
            assert(circle !is null);
            d.run(5.minutes, 1.seconds);
            d.handoff();
            assert(d.loadedObject(tribute) !is null && d.loadedObject(tribute).guid == chestGuid,
                "the unopened chest arrived");
            assert(d.loadedObject(ritualCircle) !is null && d.loadedObject(ritualCircle).guid == circle.guid,
                "the scripted summon arrived with the same GUID");
            d.run((deadline - d.w.context.unixTime - 1).seconds, 1.seconds);
            assert(d.loadedObject(tribute) !is null, "the unopened chest lasts until its original deadline");
            d.run(1.seconds, 1.seconds);
            assert(d.loadedObject(tribute) is null, "the unopened chest expires at its original deadline");
            assert(d.loadedObject(ritualCircle) !is null, "the other object's deadline is independent");
            d.run(2.seconds, 1.seconds);
            assert(d.loadedObject(ritualCircle) is null, "the scripted summon expires at its original deadline");
            continue;
        }
        d.goTo(chest.position);
        d.defend(herald); // any demons pulled during the run still attack after the coronation
        d.run(1.seconds);
        if (!d.player.knowsSpell(opening))
            d.player.spells ~= opening;
        ByteWriter request;
        request.put(opening);
        request.put(cast(ushort) TargetFlags.locked);
        request.putPackedGuid(chest.guid);
        d.party[0].write(Opcode.CMSG_CAST_SPELL, request.data);
        const result = bodyOf(d.party[0].read(), Opcode.SMSG_CAST_RESULT);
        assert(d.runUntil(() => chest.loot !is null, 12.seconds),
            format!"the chest can be opened after %s guard kills (cast result %s)\n%s"(kills,
                result.length >= 6 ? cast(SpellCastResult) result[5] : SpellCastResult.ok, d.story));
        uint equipment;
        foreach (item; chest.loot.items)
            equipment += item.itemId != 8766 && item.itemId != 8952 && item.itemId != 13444 && item.itemId != 13446;
        assert(equipment == (kills == 0 ? 5 : kills == 1 ? 4 : 0),
            format!"%s tribute bosses killed, %s equipment drops"(kills, equipment));

        if (kills == 0)
        {
            d.handoff();
            chest = d.loadedObject(tribute);
            assert(chest !is null && chest.loot !is null && chest.loot.storeReward !is null,
                "the new owner can checkpoint awards");
            d.player.spells ~= opening;
            d.party[0].write(Opcode.CMSG_CAST_SPELL, request.data);
            d.run(6.seconds);
            auto claimed = chest.loot.itemInSlot(2); // first equipment slot
            assert(claimed !is null);
            const itemId = claimed.itemId;
            d.party[0].write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(claimed.slot));
            assert(claimed.allowed.length == 0 && d.itemCount(itemId) == 1, "the first award reached the bags");
            const savedSlots = chest.loot.items.dup;
            d.restartAfterCrash();
            chest = d.loadedObject(tribute);
            assert(chest !is null && chest.loot !is null, "the partially looted chest survives recovery");
            uint awarded;
            foreach (guid, item; d.w.db.itemRows)
                if (item.entry == itemId && d.w.db.itemOwners[guid] == d.player.data.guid)
                    awarded += item.count;
            assert(chest.loot.items.length == savedSlots.length && awarded == 1);
            foreach (item; savedSlots)
            {
                auto restored = chest.loot.itemInSlot(item.slot);
                assert(restored.itemId == item.itemId && restored.count == item.count
                    && restored.randomPropertyId == item.randomPropertyId
                    && restored.allowed.keys == item.allowed.keys, "same roll and claims");
            }
            if (!d.player.knowsSpell(opening))
                d.player.spells ~= opening;
            d.party[0].write(Opcode.CMSG_CAST_SPELL, request.data);
            d.run(6.seconds);
            foreach (item; chest.loot.items)
                if (d.player.guid in item.allowed)
                    d.party[0].write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(item.slot));
            d.party[0].write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(chest.guid));
            d.run(1.seconds);
            assert(d.loadedObject(tribute) is null, "the exhausted chest has gone");
            d.restart();
            assert(d.runUntil(&atThrone, 90.seconds), "Mizzle is still available to coronate players after a restart");
            herald = d.find(mizzle);
            d.talkTo(herald);
            if (d.player.auras.find(coronation) is null)
            {
                d.choose(herald, 0);
                d.run(1.seconds);
                d.choose(herald, 0);
            }
            d.choose(herald, 0);
            d.choose(herald, 0);
            d.run(5.seconds);
            assert(d.loadedObject(tribute) is null, "a restart and repeat dialogue cannot award tribute twice");
        }
    }
}
