/**
 * The world's scripts on the real data: escort quests, quest events, guards, world objects and area triggers on the
 * continents, with characters of the race and level their quests ask for, the creatures the world database spawns.
 *
 * The escorts are found in the scripts themselves: every `@creature` script that starts an `Escort` when a quest is
 * accepted (`escort.start` beside `e.quest != <quest>`), its creatures by `ScriptName`. Each is taken on through its
 * quest giver's packet as a client does (the quests before it in its chain counted as done), followed (the character
 * keeps within reach of it, its ambushers slain), and must walk its `script_waypoint` path to the end and complete
 * the quest; taken on and left behind (80 yards) it must fail the quest.
 *
 * Runs only with the real data (`DMANGOS_REAL_DATA`).
 */
module dmangos.world.realscripts_world;

version (unittest):

import core.time : msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.world.creature : Creature;
import dmangos.world.movement : Position;
import dmangos.world.quests : QuestState;
import dmangos.world.realscriptkit_raids;
import dmangos.world.realscripts_raids : realData;
import dmangos.world.realspelltests : haveRealData;
import dmangos.world.worlddata : WorldData;

/// An escort quest a script runs: the script's name, its creature, the quest that starts it.
struct EscortCase
{
    string script;
    uint entry;
    uint quest;
    bool escort; /// an `Escort` (else another quest event: a fight, a scene)
}

/**
 * The escorts of the scripts' sources: each `@creature` block that calls `escort.start` with the quests it compares
 * `e.quest` against, resolved by the block's constants, then the file's; its creatures by `ScriptName`.
 */
EscortCase[] escortCases(const WorldData data)
{
    import std.algorithm.sorting : sort;
    import std.conv : to;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildNormalizedPath, dirName;
    import std.regex : ctRegex, matchAll;

    enum constant = ctRegex!`\b([A-Za-z_]\w*)\s*=\s*(\d[\d_]*)u?\b`;
    enum compared = ctRegex!`e\.quest\s*[!=]=\s*([A-Za-z_]\w*|\d+)`;
    enum attribute = ctRegex!`(?m)^@creature\(([^)]*)\)`;
    enum name = ctRegex!`"([^"]*)"`;
    uint[string] constantsOf(string text)
    {
        uint[string] found;
        foreach (m; matchAll(text, constant))
            if (m[1] !in found)
            {
                import std.array : replace;

                found[m[1]] = m[2].replace("_", "").to!uint;
            }
        return found;
    }

    EscortCase[] cases;
    const dir = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "scripts");
    foreach (file; dirEntries(dir, "*.d", SpanMode.shallow))
    {
        const text = readText(file.name);
        const global = constantsOf(text);
        size_t[] starts;
        string[][] names;
        foreach (m; matchAll(text, attribute))
        {
            starts ~= m.pre.length;
            string[] n;
            foreach (q; matchAll(m[1], name))
                n ~= q[1].idup;
            names ~= n;
        }
        foreach (k, start; starts)
        {
            const block = text[start .. k + 1 < starts.length ? starts[k + 1] : text.length];
            const escort = block.canFind("escort.start(");
            if (!escort && !block.canFind("const ref QuestAccepted"))
                continue;
            const local = constantsOf(block);
            foreach (m; matchAll(block, compared))
            {
                if (escort && m.hit.canFind("=="))
                    continue; // (an escort's quest is the one its `QuestAccepted` turns away the others of)
                uint quest;
                if (m[1][0] >= '0' && m[1][0] <= '9')
                    quest = m[1].to!uint;
                else if (const v = m[1] in local)
                    quest = *v;
                else if (const v = m[1] in global)
                    quest = *v;
                if (!quest || data.quests.quest(quest) is null)
                    continue;
                foreach (scriptName; names[k])
                    foreach (entry, sn; data.creatureScriptNames)
                        if (sn == scriptName && (scriptName != "npc_doctor"
                            || data.quests.creatureStarts.get(entry, null).canFind(quest)))
                            if (!cases.canFind!(x => x.entry == entry && x.quest == quest))
                                cases ~= EscortCase(scriptName, entry, quest, escort);
            }
        }
    }
    cases.sort!((a, b) => a.script < b.script || (a.script == b.script && a.quest < b.quest));
    return cases;
}

/// The first spawn of `entry` on a continent; its map 2 if none.
private Position spawnOnContinent(const WorldData data, uint entry, out uint map)
{
    foreach (const ref s; data.creatureSpawns)
        if (s.entry == entry && (s.map == 0 || s.map == 1))
        {
            map = s.map;
            return Position(s.x, s.y, s.z, s.orientation);
        }
    map = 2;
    return Position.init;
}

/// The race a quest's `RequiredRaces` lets take it (the first it names; a human if any may).
private ubyte raceFor(uint requiredRaces, bool horde)
{
    if (requiredRaces == 0)
        return horde ? 2 : 1;
    foreach (ubyte r; 1 .. 9)
        if (requiredRaces & (1 << (r - 1)))
            return r;
    return 1;
}

/// The game objects the player of an escort uses on its way, by the escort's entry (its script waits for them).
private immutable uint[][uint] objectsUsed;

shared static this()
{
    objectsUsed = [
        12717: [178247u],         // Muglash: the Naga Brazier
        10300: [177417u, 177404], // Ranshalla: the fires of Elune, the altar
        7956: [143979u],         // Kindal: the bamboo cage
    ];
}

/// Lines of `script_texts` an escort's scene must have had said by its end (complete or not), by its entry.
private immutable int[][uint] mustSay;

shared static this()
{
    mustSay = [
        // Taelan: Tirion comes (his escort kept within reach of the player) and challenges Isillien.
        1842: [-1_001_094, -1_001_096, -1_001_097],
    ];
}

/// The creature that walks a quest giver's quest in its stead, by the giver's entry.
private immutable uint[uint] escortOf;
/// Whom a creature that follows the player is to be led to (its script completes near it), by its entry.
private immutable uint[uint] leadsTo;

shared static this()
{
    escortOf = [4963: 4962]; // Mikhail: Tapoke "Slim" Jahn
    leadsTo = [
        11218: 11219, // Kerlonian Evershade to Liladris Moonriver
        9999: 9997,   // Ringo to Spraggle Frock
        3568: 3519,   // Mist to Sentinel Arynia Cloudsbreak
        7774: 7765,   // Shay Leafrunner to Rockbiter
        5955: 6015,   // Tooga to Torta
    ];
}

/// Reusable items that bring a follower back or wake it.
private immutable uint[uint] followerItems;

shared static this()
{
    followerItems = [11218: 13536, 7774: 9189, 9999: 11804]; // horn, bell, canteen
}

/// Performs the player interactions at each of Windsor's stops in the prison.
private void driveJailBreak(Scene scene, ref size_t next)
{
    import dmangos.scripts.blackrockdepths : MarshalWindsor, dughal, tobias, jaz, ograbisi, shill, crest;

    struct Stop
    {
        int line;
        uint door;
        uint[2] prisoners;
        bool free;
    }
    static immutable Stop[] stops = [
        Stop(MarshalWindsor.sayDughal1, 170562, [dughal, 0], true),
        Stop(MarshalWindsor.sayJaz1, 170568, [jaz, ograbisi]),
        Stop(MarshalWindsor.sayShill1, 170569, [shill, 0]),
        Stop(MarshalWindsor.sayCrest1, 170567, [crest, 0]),
        Stop(MarshalWindsor.sayTobias1, 170566, [tobias, 0], true),
    ];
    if (next >= stops.length || !scene.said(stops[next].line))
        return;
    const stop = stops[next];
    auto doors = scene.objects(stop.door);
    if (!doors.length)
        return;
    foreach (entry; stop.prisoners)
        if (entry && scene.find(entry) is null)
            return;
    scene.moveHero(0, doors[0].position);
    scene.use(doors[0]);
    foreach (entry; stop.prisoners)
        if (auto prisoner = scene.find(entry))
        {
            scene.moveHero(0, prisoner.position);
            if (stop.free)
                scene.gossip(prisoner, [0u]);
            else
                scene.kill(prisoner);
        }
    ++next;
}

/// Tracks each patient from admission to the start of its bandage cast.
private struct TriageTreatment
{
    enum uint bandage = 16991;
    enum long castMs = 7000;
    static immutable uint[2][3] patientEntries = [[12923u, 12938], [12924u, 12936], [12925u, 12937]];
    static immutable long[3] lifetimeMs = [26_000L, 18_000L, 12_000L];

    bool[ulong] treated;
    long[ulong] admitted;
    long readyAt;

    void bandageNext(Scene scene, Creature doctor)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        const now = scene.elapsedMs;
        Creature next;
        long earliest = long.max;
        foreach (severity, entries; patientEntries)
            foreach (entry; entries)
                foreach (patient; scene.all(entry))
                    if (patient.summon.summoner == doctor.guid && patient.guid !in treated)
                    {
                        const deadline = admitted.require(patient.guid, now) + lifetimeMs[severity];
                        if (now + castMs < deadline && deadline < earliest)
                        {
                            next = patient;
                            earliest = deadline;
                        }
                    }
        if (next is null || now < readyAt)
            return;
        scene.moveHero(0, next.position);
        if (scene.useCarriedItem(bandage, SpellTargets(TargetFlags.unit, next.guid)) == 0)
        {
            treated[next.guid] = true;
            readyAt = now + castMs;
        }
    }
}

/// What an escort came to: "" if it did its part, else why not.
string runEscort(const EscortCase c, bool leave, out long ms, bool only = false)
{
    import std.algorithm.comparison : clamp, max;
    import dmangos.scripts.felwood : Arei;
    import dmangos.scripts.feralas : GrimtotemCageDoor, KindalMoonweaver;
    import dmangos.scripts.moonglade : KeeperRemulos, Eranikus;
    import dmangos.scripts.npcs : questTriageAlliance, questTriageHorde;
    import dmangos.scripts.stormwind : ReginaldWindsor, SquireRowe, questGreatMasquerade, questStormwindRendezvous;
    import dmangos.world.quests : QuestStatus;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.updatefields : UNIT_NPC_FLAGS;

    uint mapId;
    const data = realData;
    const needsRowe = c.quest == questGreatMasquerade;
    enum uint squireRowe = 17804;
    const spawnEntry = needsRowe ? squireRowe : c.entry;
    auto at = spawnOnContinent(data, spawnEntry, mapId);
    if (mapId == 2)
        foreach (const ref spawn; data.creatureSpawns)
            if (spawn.entry == spawnEntry)
            {
                mapId = spawn.map;
                at = Position(spawn.x, spawn.y, spawn.z, spawn.orientation);
                break;
            }
    const needsFlute = c.quest == Arei.questAncientSpirit;
    if (needsFlute)
    {
        // The flute needs the spell focus at the Irontree Woods ruins (object 165760).
        mapId = 1;
        at = Position(5968.89f, -1212.05f, 379.832f);
    }
    if (mapId == 2)
        return "no static spawn";
    const q = data.quests.quest(c.quest);
    const triage = c.quest == questTriageAlliance || c.quest == questTriageHorde;
    const level = clamp(max(q.minLevel, q.questLevel > 0 ? q.questLevel : 1), 1, 60);
    string why;
    foreach (horde; [false, true])
    {
        Position heroAt = at;
        heroAt.x += 3;
        ubyte classId = classWarrior;
        foreach (ubyte k; 1 .. 12)
            if (q.requiredClasses & (1 << (k - 1)))
            {
                classId = k;
                break;
            }
        auto race = raceFor(q.requiredRaces, horde);
        if (classId == 2 && race != 1 && race != 3) // a paladin: a human or a dwarf
            race = 1;
        else if (classId == 7 && race != 2 && race != 6 && race != 8) // a shaman: an orc, a tauren or a troll
            race = 2;
        auto s = new Scene(mapId, heroAt, Race(race), classId, level);
        s.run(600.msecs);
        if (needsFlute)
        {
            enum uint flute = 11445, purified = 4442;
            s.hero.questStatus[purified] = QuestStatus(purified, QuestState.none, true);
            s.heroes[0].session.inWorld.storeLoot(flute, 1, 0, false);
            const result = s.useCarriedItem(flute, SpellTargets(TargetFlags.self));
            if (!s.runUntil(() => s.find(c.entry) !is null, 10.seconds))
                return format!"the flute did not summon Arei (cast result %s)"(result);
            s.moveHero(0, s.the(c.entry).position);
        }
        auto npc = s.find(spawnEntry);
        if (npc is null)
            return "not up where it spawns (a pool, an event)";
        if (needsRowe)
        {
            s.hero.questStatus[questStormwindRendezvous] = QuestStatus(questStormwindRendezvous, QuestState.none, true);
            s.stayWith = npc;
            s.gossip(npc, [0u]);
            if (!s.runUntil(() => s.said(SquireRowe.sayWelcome), 90.seconds))
                return "Squire Rowe did not summon and introduce Windsor";
            npc = s.the(c.entry);
            s.moveHero(0, npc.position);
        }
        if (q.requiredMinRepFaction)
        {
            auto rep = s.hero.reputation;
            const faction = s.w.context.client.factions.lookup(q.requiredMinRepFaction);
            if (rep.standingWith(faction) < q.requiredMinRepValue)
                rep.change(faction, q.requiredMinRepValue, false, null, true);
        }
        if (triage)
            assert(s.hero.setSkill(q.requiredSkill, cast(ushort) q.requiredSkillValue, cast(ushort) q.requiredSkillValue));
        if (!s.takeQuest(npc, c.quest))
        {
            why = format!"the quest not taken (its giver's NPC flags %#x)"(npc.values.get!UNIT_NPC_FLAGS);
            if (q.requiredRaces == 0 && !horde)
                continue;
            return why;
        }
        // One whose quest another walks (Mikhail's: Slim) is followed in its stead.
        if (const other = c.entry in escortOf)
        {
            s.run(2.seconds);
            npc = s.find(*other);
            if (npc is null)
                return format!"no %s comes to walk"(*other);
        }
        s.stayWith = npc;
        s.stayWithin = 8;
        s.pressing = false;
        // The patient can be several yards from the doctor. Stay beside the patient for the entire cast.
        if (triage)
            s.stayWith = null;
        // One that follows the player is led to whom it is to find, at a walk.
        Position leadTo;
        if (const target = c.entry in leadsTo)
        {
            uint m;
            leadTo = spawnOnContinent(data, *target, m);
            s.stayWith = null;
        }
        if (c.entry == 7850) // Kernobee follows the player to the clean zone door.
        {
            const exit = imported!"dmangos.scripts.gnomeregan".Kernobee.endPlace;
            leadTo = Position(exit.x, exit.y, exit.z);
            s.stayWith = null;
        }
        enum uint questFreeCreatures = KindalMoonweaver.questFreedom, cageDoor = 143979;
        if (c.quest == questFreeCreatures)
        {
            float closest = float.infinity;
            foreach (cage; s.objects(cageDoor))
            {
                const away = Scene.distance(npc.position, cage.position);
                if (away < closest)
                {
                    closest = away;
                    leadTo = cage.position;
                }
            }
            s.stayWith = null;
        }
        if (leave)
        {
            s.run(3.seconds);
            s.stayWith = null;
            auto far = npc.position;
            far.x += 80;
            s.moveHero(0, far);
            const failed = s.runUntil(() => s.questState(c.quest) == QuestState.failed, 30.seconds);
            ms = s.elapsedMs;
            return failed ? "" : format!"left 80 yards behind, the quest is %s"(s.questState(c.quest));
        }
        const followerItem = followerItems.get(c.entry, 0);
        if (followerItem && !s.hero.inventory.count(followerItem))
            s.heroes[0].session.inWorld.storeLoot(followerItem, 1, 0, false);
        const end = data.escortPaths.get(c.entry, null);
        float nearest = float.infinity;
        bool[ulong] used;
        const toUse = c.entry in objectsUsed;
        size_t jailStop;
        bool readyAtKeep;
        TriageTreatment treatment;
        enum uint eranikus = 15491;
        const over = s.runUntil(() {
            import dmangos.scripts.blackrockdepths : MarshalWindsor;
            import dmangos.world.updatefields : UNIT_FIELD_BYTES_1;
            import dmangos.script.api : StandState;

            // Dorius's marksman must finish his shot. Eranikus must survive at low health.
            const spare = c.entry == 8284 ? 8338 : c.quest == KeeperRemulos.questNightmareManifests ? eranikus : 0;
            s.killAttackers(npc, 60, spare);
            if (c.quest == questFreeCreatures)
                foreach (darter; s.all(GrimtotemCageDoor.spriteDarter))
                    s.killAttackers(darter);
            if (c.quest == KeeperRemulos.questNightmareManifests && s.said(Eranikus.sayAttack2))
                if (auto dragon = s.find(eranikus))
                    s.hurtTo(dragon, 18);
            if (c.quest == MarshalWindsor.quest)
                driveJailBreak(s, jailStop);
            if (triage)
                treatment.bandageNext(s, npc);
            if (needsRowe)
            {
                if (!readyAtKeep && npc.values.get!UNIT_NPC_FLAGS & ReginaldWindsor.npcFlagGossip)
                {
                    s.moveHero(0, npc.position);
                    s.gossip(npc, [0u]);
                    readyAtKeep = true;
                }
                foreach (guard; s.all(ReginaldWindsor.onyxiaGuard))
                    s.kill(guard);
            }
            const asleep = npc.values.getByte!UNIT_FIELD_BYTES_1(0) == StandState.sleep;
            if (!asleep && leadTo.x != 0 && s.elapsedMs % 1000 == 0 && Scene.distance(s.hero.position, leadTo) > 3
                    && Scene.distance(s.hero.position, npc.position) < 20)
            {
                auto p = s.hero.position;
                const d = Scene.distance(p, leadTo), step = d < 3 ? d : 3;
                p.x += (leadTo.x - p.x) / d * step;
                p.y += (leadTo.y - p.y) / d * step;
                p.z += (leadTo.z - p.z) / d * step;
                s.moveHero(0, Position(p.x - 2, p.y, p.z)); // (`moveHero` stands two yards east of where it is told)
            }
            const distance = Scene.distance(s.hero.position, npc.position);
            if (followerItem && s.elapsedMs % 5000 == 0 && (asleep || (c.entry == 7774 && distance > 8)))
            {
                if (distance > 4)
                    s.moveHero(0, npc.position);
                s.useCarriedItem(followerItem, SpellTargets(TargetFlags.unit, npc.guid));
            }
            // What the player must use on the way (a brazier to light, the fires of Elune), once each, as the escort
            // comes by it.
            if (toUse !is null && s.elapsedMs % 1000 == 0)
                foreach (entry; *toUse)
                    foreach (go; s.objects(entry))
                        if (go.guid !in used && Scene.distance(go.position, npc.position) < 20
                            && !(go.values.get!(imported!"dmangos.world.updatefields".GAMEOBJECT_FLAGS) & 0x10))
                        { // (usable: its script took its "no interaction" flag away)
                            if (c.quest == questFreeCreatures && !s.hero.inventory.count(q.srcItemId))
                                continue;
                            used[go.guid] = true;
                            s.moveHero(0, go.position);
                            s.run(400.msecs);
                            if (c.quest == questFreeCreatures)
                            {
                                auto targets = SpellTargets(TargetFlags.gameObject);
                                targets.gameObject = go.guid;
                                s.useCarriedItem(q.srcItemId, targets);
                            }
                            else
                                s.use(go);
                        }
            // One that fights the character (a challenge, a capture) is fought: a twentieth of its health a second.
            if (s.elapsedMs % 1000 == 0 && npc.alive && npc.ai.inCombat && npc.ai.hostVictim().guid == s.hero.guid)
            {
                import dmangos.world.unit : Blow, dealDamage;
                import dmangos.world.updatefields : UNIT_FIELD_MAXHEALTH;

                dealDamage(s.heroUnit, s.map.unitOf(npc), npc.values.get!UNIT_FIELD_MAXHEALTH / 20, Blow.spell());
            }
            if (end.length && npc.alive)
            {
                const d = Scene.distance(npc.position, Position(end[$ - 1].at.x, end[$ - 1].at.y, end[$ - 1].at.z));
                if (d < nearest)
                    nearest = d;
            }
            const st = s.questState(c.quest);
            return st == QuestState.complete || st == QuestState.failed || !npc.alive;
        }, 1200.seconds);
        ms = s.elapsedMs;
        if (const lines = c.entry in mustSay)
            foreach (line; *lines)
                if (!s.said(line))
                    return format!"line %s not said"(line);
        if (only)
            imported!"std.stdio".writeln(s.seen()); // (one escort looked at alone: what it did)
        const st = s.questState(c.quest);
        if (st == QuestState.complete) // (some complete before their path's end: the rest is their way home)
            return "";
        if (!over)
            return format!"not over in 20 minutes (%.0f yards from its path's end, at %s)"(nearest, npc.position);
        return !npc.alive ? "the escort died" : format!"failed (%.0f yards from its path's end)"(nearest);
    }
    return why;
}

/// Runs every case and fails if any cannot complete or leave-behind handling fails.
private void sweepQuests(const EscortCase[] cases, string what)
{
    import std.process : environment;
    import std.stdio : writeln;

    string[] failures;
    size_t done, ran;
    const only = environment.get("DMANGOS_ESCORTS_ONLY"); // script names, comma separated: those alone, said at length
    foreach (c; cases)
    {
        if (only !is null && !only.canFind(c.script))
            continue;
        ++ran;
        long ms, msLeft;
        const why = runEscort(c, false, ms, only !is null);
        const whyLeft = why.length || !c.escort ? "" : runEscort(c, true, msLeft);
        const outcome = why.length ? why : whyLeft;
        const key = format!"%s/%s"(c.script, c.quest);
        writeln(format!"realscripts_world: %s (%s, quest %s): %s in %s s"(c.script, c.entry, c.quest,
            outcome.length ? outcome : "ok", ms / 1000));
        if (outcome.length == 0)
            ++done;
        else
            failures ~= format!"%s: %s"(key, outcome);
    }
    writeln(format!"realscripts_world: %s %s, %s passed, %s failed"(ran, what, done, failures.length));
    assert(failures.length == 0, format!"%s that do not do their part:\n%-(%s\n%)"(what, failures));
}

/// Every escort quest of the scripts: taken on, followed to the end, its quest complete; left behind, failed.
unittest
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    if (!haveRealData())
        return;
    const cases = escortCases(realData).filter!(c => c.escort).array;
    assert(cases.length >= 30, format!"only %s escorts found in the scripts"(cases.length));
    sweepQuests(cases, "escorts");
}

/**
 * The other quests a creature's script answers the taking of (a challenge, a capture, a scene, a summoning): taken
 * on, its creature fought if it fights, what happens followed; its quest complete in the end.
 */
unittest
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    if (!haveRealData())
        return;
    const cases = escortCases(realData).filter!(c => !c.escort).array;
    sweepQuests(cases, "quest events");
}

// ---------------------------------------------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------------------------------------------

/// An Orgrimmar Grunt (3296) answers a Horde player's kiss with a bow, and not an Alliance one's.
unittest
{
    import dmangos.world.packets : ClientTextEmote;
    import dmangos.world.opcodes : Opcode;

    if (!haveRealData())
        return;
    enum uint grunt = 3296, textKiss = 58, emoteBow = 2;
    uint map;
    auto at = spawnOnContinent(realData, grunt, map);
    foreach (horde; [true, false])
    {
        Position heroAt = at;
        heroAt.x += 2;
        auto s = new Scene(map, heroAt, Race(horde ? 2 : 1), classWarrior, 60);
        s.run(400.msecs);
        auto him = s.the(grunt);
        s.forget();
        s.heroes[0].write(Opcode.CMSG_TEXT_EMOTE, ClientTextEmote(textKiss, 0, him.guid));
        s.run(1.seconds);
        assert(s.emotes.canFind(emoteBow) == horde, format!"a grunt's bow to a %s's kiss: %s"(horde ? "Horde" : "Alliance",
            s.emotes));
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Area triggers
// ---------------------------------------------------------------------------------------------------------------

/// An area trigger's script: walked into (`AreaTrigger.dbc`'s place) by a character on its quest, what must follow.
struct TriggerCase
{
    string script;
    uint trigger;          /// `scripted_areatrigger.entry`
    uint quest;            /// the character is on it (0: none)
    bool questComplete;    /// ... with it complete
    ubyte race, classId;
    uint level;
    uint[2][] summons;     /// [entry, at least]: alive near within the time
    int text;              /// a `script_texts` line said (0: none)
    bool completes;        /// the quest is complete after
    uint seconds = 3;
}

/**
 * The area triggers of the world's scripts: the Manor Ravenholdt counts for its quest; the Twilight Grove calls the
 * Twilight Corrupter (his line); the Ancient Leaf's grove its three ancients; the Hive'Ashi tower its three drones;
 * Darkshore's beach calls Murkdeep's Greymist ashore (the world map's script). And none of it without the quest.
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable TriggerCase[] cases = [
        TriggerCase("at_ravenholdt", 3066, 6681, false, 1, 4, 24, null, 0, true),
        TriggerCase("at_twilight_grove", 4017, 8735, false, 1, 1, 60, [[15625, 1]], -1_000_411),
        TriggerCase("at_ancient_leaf", 3587, 7632, true, 4, 3, 60, [[14524, 1], [14525, 1], [14526, 1]]),
        TriggerCase("at_hive_tower", 3146, 0, false, 1, 1, 60, [[13136, 3]]),
        TriggerCase("at_murkdeep", 1966, 4740, false, 4, 1, 20, [[2202, 1]], 0, false, 40),
    ];
    foreach (c; cases)
        foreach (onQuest; c.quest ? [false, true] : [true])
        {
            const entry = realData.areaTriggerScriptNames.get(c.trigger, null);
            assert(entry == c.script, format!"trigger %s is %s, not %s"(c.trigger, entry, c.script));
            auto s = new Scene(0, Position(-8835, 615, 93), Race(c.race), c.classId, c.level);
            const at = s.w.context.client.areaTriggers.lookup(c.trigger);
            assert(at !is null, format!"%s: no trigger %s"(c.script, c.trigger));
            s = new Scene(at.mapId, Position(at.x + 30, at.y, at.z), Race(c.race), c.classId, c.level);
            s.run(1.seconds);
            if (onQuest && c.quest)
                s.giveQuest(c.quest, c.questComplete);
            size_t[2][] before;
            foreach (sm; c.summons)
                before ~= [sm[0], s.all(sm[0]).length];
            s.forget();
            s.enterTrigger(c.trigger);
            s.run(c.seconds.seconds);
            foreach (k, sm; c.summons)
            {
                const now = s.all(sm[0]).length;
                if (onQuest)
                    assert(now >= before[k][1] + sm[1], format!"%s: %s of %s, %s more wanted"(c.script, now,
                        sm[0], sm[1]));
                else
                    assert(now == before[k][1], format!"%s: %s came without the quest"(c.script, sm[0]));
            }
            if (onQuest && c.text)
                assert(s.said(c.text), format!"%s: line %s not said\n%s"(c.script, c.text, s.seen()));
            if (c.completes)
                assert((s.questState(c.quest) == QuestState.complete) == onQuest, format!"%s: the quest %s"(c.script,
                    s.questState(c.quest)));
        }
}
