/**
 * The world's scripts on the real data: escort quests, quest events, guards, world objects and area triggers on the
 * continents, with characters of the race and level their quests ask for, the creatures the world database spawns.
 *
 * The escorts are found in the scripts themselves: every `@creature` script that starts an `Escort` when a quest is
 * accepted (`escort.start` beside `e.quest != <quest>`), its creatures by `ScriptName`. Each is taken on through its
 * quest giver's packet as a client does (the quests before it in its chain counted as done), followed (the character
 * keeps within reach of it, its ambushers slain), and must walk its `script_waypoint` path to the end and complete
 * the quest; taken on and left behind (80 yards) it must fail the quest. What cannot be so is listed in
 * `knownEscorts`, with why; the test fails at an escort not listed that does not do its part, and says which listed
 * ones pass now.
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
    enum compared = ctRegex!`e\.quest\s*!=\s*([A-Za-z_]\w*|\d+)`;
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
            if (!block.canFind("escort.start("))
                continue;
            const local = constantsOf(block);
            foreach (m; matchAll(block, compared))
            {
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
                        if (sn == scriptName)
                            cases ~= EscortCase(scriptName, entry, quest);
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

/// What an escort came to: "" if it did its part, else why not.
string runEscort(const EscortCase c, bool leave, out long ms, bool only = false)
{
    import std.algorithm.comparison : clamp, max;

    uint mapId;
    const data = realData;
    auto at = spawnOnContinent(data, c.entry, mapId);
    if (mapId == 2)
        return "no spawn on a continent";
    const q = data.quests.quest(c.quest);
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
        auto npc = s.find(c.entry);
        if (npc is null)
            return "not up where it spawns (a pool, an event)";
        if (!s.takeQuest(npc, c.quest))
        {
            import dmangos.world.updatefields : UNIT_NPC_FLAGS;

            why = format!"the quest not taken (its giver's NPC flags %#x)"(npc.values.get!UNIT_NPC_FLAGS);
            if (q.requiredRaces == 0 && !horde)
                continue;
            return why;
        }
        s.stayWith = npc;
        s.stayWithin = 8;
        s.pressing = false;
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
        const end = data.escortPaths.get(c.entry, null);
        float nearest = float.max;
        bool[ulong] used;
        const toUse = c.entry in objectsUsed;
        const over = s.runUntil(() {
            s.killAttackers(npc);
            // What the player must use on the way (a brazier to light, the fires of Elune), once each, as the escort
            // comes by it.
            if (toUse !is null && s.elapsedMs % 1000 == 0)
                foreach (entry; *toUse)
                    foreach (go; s.objects(entry))
                        if (go.guid !in used && Scene.distance(go.position, npc.position) < 20
                            && !(go.values.get!(imported!"dmangos.world.updatefields".GAMEOBJECT_FLAGS) & 0x10))
                        { // (usable: its script took its "no interaction" flag away)
                            used[go.guid] = true;
                            s.moveHero(0, go.position);
                            s.run(400.msecs);
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

/// The escorts that cannot do their part on this data, and why (each a reason found by the test, kept honest by it).
private immutable string[string] knownEscorts;

shared static this()
{
    knownEscorts = [
        // Dungeons' escorts (their tests are the dungeons'): no spawn on a continent.
        "npc_belnistrasz/3525": "no spawn on a continent", // Razorfen Downs
        "npc_marshal_windsor/4322": "no spawn on a continent", // Blackrock Depths
        "npc_willix_the_importer/1144": "no spawn on a continent", // Razorfen Kraul
        // No spawn in this world database, and nothing summons them.
        "npc_arei/4261": "no spawn on a continent", // Arei (9598)
        "npc_reginald_windsor/6403": "no spawn on a continent", // Reginald Windsor (12580)
        // The quest asks for neutral with the Brood of Nozdormu (`RequiredMinRepFaction` 910).
        "npc_keeper_remulos/8736": "the quest not taken",
        // The Dark Iron Marksman's shot (12198) is cast by its relay script on spawn (`creature_spawn_data_template`
        // 8338, `RelayId`), which the database scripts' summon (command 10, `dataint4`) does not run here.
        "npc_dorius_stonetender/3367": "not over in 20 minutes",
        // Isillien struck Taelan down, Tirion came and challenged him, and their fight does not end Isillien (he
        // heals; Tirion fights only when told): the epilogue never comes.
        "npc_taelan_fordring/5944": "not over in 20 minutes",
    ];
}

/// Every escort quest of the scripts: taken on, followed to the end, its quest complete; left behind, failed.
unittest
{
    import std.stdio : writeln;

    if (!haveRealData())
        return;
    const cases = escortCases(realData);
    assert(cases.length >= 30, format!"only %s escorts found in the scripts"(cases.length));
    string[] fresh, passesNow;
    size_t done;
    import std.process : environment;

    const only = environment.get("DMANGOS_ESCORTS_ONLY"); // script names, comma separated: those alone, said at length
    foreach (c; cases)
    {
        if (only !is null && !only.canFind(c.script))
            continue;
        long ms, msLeft;
        const why = runEscort(c, false, ms, only !is null);
        const whyLeft = why.length ? "" : runEscort(c, true, msLeft);
        const outcome = why.length ? why : whyLeft;
        const key = format!"%s/%s"(c.script, c.quest);
        writeln(format!"realscripts_world: %s (%s, quest %s): %s in %s s"(c.script, c.entry, c.quest,
            outcome.length ? outcome : "ok", ms / 1000));
        const knownWhy = key in knownEscorts;
        const known = knownWhy !is null && outcome.canFind(*knownWhy); // known only as far as it fails as it did
        if (outcome.length == 0)
        {
            ++done;
            if (known)
                passesNow ~= key;
        }
        else if (!known)
            fresh ~= format!"%s: %s"(key, outcome);
    }
    writeln(format!"realscripts_world: %s escorts, %s do their part, %s known not to"(cases.length, done,
        cases.length - done));
    foreach (p; passesNow)
        writeln("realscripts_world: passes now, take it off knownEscorts: ", p);
    if (only !is null)
        return;
    assert(fresh.length == 0, format!"escorts that do not do their part:\n%-(%s\n%)"(fresh));
}
