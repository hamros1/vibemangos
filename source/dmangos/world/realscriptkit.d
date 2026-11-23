/**
 * What a test of a dungeon's scripts on the real data needs (`dmangos.world.realscripts_dungeons`): a character in a
 * copy of the real map, the real creatures of its world database spawns (or the scripts' own summons), the world's
 * tick run for a while, and what the client was told meanwhile: the creatures' lines (`script_texts`), their casts
 * (`SMSG_SPELL_START`, `SMSG_SPELL_GO`), the creatures summoned, the doors' states, the copy's saved `instance.data`.
 *
 * A dungeon is entered as a player enters it (`teleportTo`, the client's `MSG_MOVE_WORLDPORT_ACK`), its entrance's
 * requirements aside; its cells load around the character, as they do for a player. The character is kept alive
 * (its health topped up each step: "god-like", so a fight can be watched to its end) unless a test wants a wipe.
 * Run only where `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`).
 */
module dmangos.world.realscriptkit;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.bytes : ByteReader;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.gameobject : GameObject;
import dmangos.world.map : Map, MapObject;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : ChatType, Opcode;
import dmangos.world.player : Player;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.testclient : TestClient;
import dmangos.world.unit : Blow, dealDamage, UnitRef;
import dmangos.world.updatefields;

public import dmangos.world.realspelltests : haveRealData;

/// A creature's line the client was told (`SMSG_MESSAGECHAT`).
struct Said
{
    ChatType type;
    ulong speaker; /// 0 for an emote (its packet names no guid)
    string name;
    string text;
}

/// A cast the client was told of.
struct Cast
{
    ulong caster;
    uint entry;  /// the caster's creature entry (0: a player's)
    uint spell;
    bool started; /// `SMSG_SPELL_START` (else `SMSG_SPELL_GO`)
}

/// A creature summoned while the test watched.
struct Summon
{
    ulong guid;
    uint entry;
    ulong summoner;
}

/// The entry of a creature's guid (`HighGuid.unit`: entry in bits 24..47).
uint entryOfGuid(ulong guid) pure nothrow @nogc @safe
{
    return (guid >> 48) == 0xF130 ? cast(uint)((guid >> 24) & 0xFF_FFFF) : 0;
}

/// See the module documentation.
final class Dungeon
{
    RealWorld w;
    TestClient[] party;   /// party[0] leads; what it is told is collected
    uint mapId;
    Said[] said;
    Cast[] casts;
    Summon[] summons;
    bool keepAlive = true; /// the party takes no damage (`.cheat god`), its health and mana topped up each step
    uint level;
    ubyte classId;
    imported!"core.time".MonoTime started; /// when the test began (for the trace)
    private bool[ulong] known; /// creatures seen (a summon is recorded once)
    /// `DMANGOS_SCRIPT_TRACE` set: what the client is told is written out as it comes.
    static bool trace;

    static this()
    {
        import std.process : environment;

        trace = environment.get("DMANGOS_SCRIPT_TRACE") !is null;
    }

    /**
     * A character of `classId` and `level` (`players` of them: a party) in a new copy of dungeon `mapId`, at its
     * entrance (`areatrigger_teleport`) or `at`.
     */
    static Dungeon enter(uint mapId, uint level, ubyte classId = 1, size_t players = 1,
        Position at = Position.init, uint seed = 20_261_120)
    {
        auto d = new Dungeon;
        d.w = RealWorld.make(seed);
        d.mapId = mapId;
        d.level = level;
        d.started = d.w.now;
        d.classId = classId;
        if (at == Position.init)
        {
            const trigger = d.w.context.data.mapEntranceTrigger(mapId, d.w.context.client);
            assert(trigger !is null, format!"map %s: no entrance"(mapId));
            at = Position(trigger.x, trigger.y, trigger.z, trigger.orientation);
        }
        foreach (i; 0 .. players)
        {
            d.party ~= d.w.character(cast(uint)(i + 1), format!"Delver%s"(cast(char)('a' + i)), classId, level, []);
            d.port(d.party[$ - 1], mapId, at, uint.max);
        }
        foreach (ref c; d.party)
            c.read();
        d.godlike();
        d.instanceId = d.party[0].session.inWorld.instanceId;
        assert(d.instanceId && d.map !is null, "in a copy");
        d.map.random.seed(seed); // its rolls the same at every run, as the world's
        return d;
    }

    /// Into map `mapId` (copy `instance`, uint.max: its own) at `at`, as the client goes: the order, the ack.
    void port(ref TestClient c, uint mapId, Position at, uint instance)
    {
        auto me = c.session.inWorld;
        const went = me.teleportTo(mapId, at, null, instance, true);
        assert(went, format!"not let into map %s"(mapId));
        c.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        c.read();
    }

    /// The character `i` of the party.
    Player player(size_t i = 0)
    {
        return cast(Player) party[i].session.character;
    }

    /// ditto, as a unit
    UnitRef unit(size_t i = 0)
    {
        return party[i].session.inWorld.unit;
    }

    /// The copy's map.
    @property Map map()
    {
        return w.context.map(mapId, instanceId);
    }

    /// The copy's id.
    uint instanceId;

    /// The copy's saved state (`instance.data`).
    @property string data()
    {
        const state = w.context.instanceState(instanceId);
        return state is null ? null : state.data;
    }

    /// The dungeon script's state as the copy saved it (`instance.data`), read into a fresh `S`.
    S saved(S)()
    {
        import std.conv : to;
        import dmangos.script.state : loadScript;
        import dmangos.world.instancescripting : instanceDataPrefix;

        S state;
        const text = data;
        assert(text.length > instanceDataPrefix.length, "nothing saved");
        ubyte[] bytes;
        for (size_t i = instanceDataPrefix.length; i + 1 < text.length; i += 2)
            bytes ~= text[i .. i + 2].to!ubyte(16);
        auto r = ByteReader(bytes);
        assert(loadScript(state, r), "the saved state is " ~ S.stringof ~ "'s");
        return state;
    }

    /// Scripted event `id` happens, character `i` its source (as a spell's `SEND_EVENT` or a goober's event): the
    /// event's script, the copy's script, then its database script.
    void event(uint id, ulong target = 0, size_t i = 0)
    {
        w.context.scriptedEvent(id, map, player(i).guid, target);
        collect();
    }

    /// Character `i` steps into area trigger `id` (`CMSG_AREATRIGGER`), standing at its centre.
    void trigger(uint id, size_t i = 0)
    {
        import dmangos.bytes : ByteWriter;

        const t = w.context.client.areaTriggers.lookup(id);
        assert(t !is null, format!"no area trigger %s"(id));
        goTo(Position(t.x, t.y, t.z), i);
        ByteWriter b;
        b.put(id);
        party[i].write(Opcode.CMSG_AREATRIGGER, b.data.dup);
        collect();
    }

    /// Character `i` takes quest `quest` from `giver` (`CMSG_QUESTGIVER_ACCEPT_QUEST`), standing beside it.
    void acceptQuest(Creature giver, uint quest, size_t i = 0)
    {
        import dmangos.bytes : ByteWriter;

        const at = giver.position;
        goTo(Position(at.x + 2, at.y, at.z), i);
        ByteWriter b;
        b.put(giver.guid);
        b.put(quest);
        party[i].write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, b.data.dup);
        collect();
    }

    /// Character `i` has done quest `quest` before (rewarded: what a quest after it needs).
    void questDone(uint quest, size_t i = 0)
    {
        import dmangos.world.quests : QuestState, QuestStatus;

        player(i).questStatus[quest] = QuestStatus(quest, QuestState.complete, true);
    }

    /// Character `i` is given `count` of item `item` (in its bags, as a quest's reward would put them); how many went in.
    uint give(uint item, uint count = 1, size_t i = 0)
    {
        const got = party[i].session.inWorld.scriptGiveItem(item, count);
        collect();
        return got;
    }

    /// How many of item `item` character `i` has.
    uint itemCount(uint item, size_t i = 0)
    {
        return player(i).inventory.count(item);
    }

    /// Where character `i` stands with quest `quest`.
    imported!"dmangos.script.api".QuestProgress questStatus(uint quest, size_t i = 0)
    {
        return unit(i).questStatusOf(quest);
    }

    /// Character `i` talks to `c` (`CMSG_GOSSIP_HELLO`), standing beside it.
    void talkTo(Creature c, size_t i = 0)
    {
        import dmangos.bytes : ByteWriter;

        const at = c.position;
        goTo(Position(at.x + 2, at.y, at.z), i);
        ByteWriter b;
        b.put(c.guid);
        party[i].write(Opcode.CMSG_GOSSIP_HELLO, b.data.dup);
        collect();
    }

    /// Character `i` picks option `option` (from 0, as the menu lists them) of `c`'s gossip menu (`CMSG_GOSSIP_SELECT_OPTION`).
    void choose(Creature c, uint option, size_t i = 0)
    {
        import dmangos.bytes : ByteWriter;

        ByteWriter b;
        b.put(c.guid);
        b.put(option);
        party[i].write(Opcode.CMSG_GOSSIP_SELECT_OPTION, b.data.dup);
        collect();
    }

    /// Moves character `i` to `at` on the map (a near teleport, acknowledged); the cells around it load.
    void goTo(Position at, size_t i = 0)
    {
        import dmangos.world.packets : ClientTeleportAck;

        auto me = party[i].session.inWorld;
        assert(me.teleportTo(mapId, at, null, uint.max, true), "teleported");
        party[i].write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
        collect();
        tick(100.msecs);
    }

    /// The world database's spawn `n` of creature `entry` on this map.
    const(imported!"dmangos.world.creature".CreatureSpawn)* spawnRow(uint entry, size_t n = 0)
    {
        foreach (ref s; w.context.data.creatureSpawns)
            if (s.map == mapId && s.entry == entry && n-- == 0)
                return &s;
        return null;
    }

    /// The world database's spawn of game object `entry` on this map.
    const(imported!"dmangos.world.gameobject".GameObjectSpawn)* objectRow(uint entry, size_t n = 0)
    {
        foreach (ref s; w.context.data.gameObjectSpawns)
            if (s.map == mapId && s.entry == entry && n-- == 0)
                return &s;
        return null;
    }

    /**
     * The creature of the world database's spawn `n` of `entry`, its cells loaded: the party's leader is moved
     * `distance` yards from it (on its x axis, at its height: out of its reach), unless it is that near already.
     */
    Creature spawned(uint entry, size_t n = 0, float distance = 60)
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        const row = spawnRow(entry, n);
        assert(row !is null, format!"map %s: no spawn of creature %s"(mapId, entry));
        const guid = makeGuid(HighGuid.unit, entry, row.guid);
        const me = player.position;
        if (((me.x - row.x) ^^ 2 + (me.y - row.y) ^^ 2 + (me.z - row.z) ^^ 2) ^^ 0.5f > distance + 5)
            goTo(Position(row.x + distance, row.y, row.z));
        auto found = cast(Creature) map.findObject(guid);
        assert(found !is null, format!"creature %s (spawn %s) not loaded"(entry, row.guid));
        return found;
    }

    /// The game object of the world database's spawn of `entry`, loaded (the party moved near it if need be).
    GameObject objectOf(uint entry, size_t n = 0)
    {
        if (auto found = loadedObject(entry))
            return found;
        const row = objectRow(entry, n);
        assert(row !is null, format!"map %s: no spawn of game object %s"(mapId, entry));
        goTo(Position(row.x + 5, row.y, row.z));
        auto found = loadedObject(entry);
        assert(found !is null, format!"game object %s not loaded"(entry));
        return found;
    }

    /// A loaded game object of `entry`, or null.
    GameObject loadedObject(uint entry)
    {
        GameObject found;
        map.forEachObject((MapObject o) {
            if (auto go = cast(GameObject) o)
                if (go.template_.entry == entry && found is null)
                    found = go;
        });
        return found;
    }

    /// A loaded creature of `entry` (living ones first), or null.
    Creature find(uint entry)
    {
        Creature found;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Creature) o)
                if (c.template_.entry == entry && (found is null || (!found.alive && c.alive)))
                    found = c;
        });
        return found;
    }

    /// Every loaded creature of `entry`.
    Creature[] all(uint entry, bool living = true)
    {
        Creature[] found;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Creature) o)
                if (c.template_.entry == entry && (!living || c.alive))
                    found ~= c;
        });
        return found;
    }

    /// A creature of `entry` put at `at` (as a script or a GM would summon it), for good.
    Creature summon(uint entry, Position at)
    {
        auto c = w.context.summonCreature(map, entry, at, TempSpawnType.manual, 0, 0);
        assert(c !is null, format!"creature %s not summoned"(entry));
        known[c.guid] = true; // the test's, not a script's
        return c;
    }

    /// Character `i` goes beside game object `go` and uses it (`CMSG_GAMEOBJ_USE`), as a player clicks it.
    void use(GameObject go, size_t i = 0)
    {
        import dmangos.bytes : ByteWriter;

        const at = go.position;
        goTo(Position(at.x + 2, at.y, at.z), i);
        ByteWriter b;
        b.put(go.guid);
        party[i].write(Opcode.CMSG_GAMEOBJ_USE, b.data.dup);
        collect();
    }

    /// The party's leader goes to `c` (`distance` yards in front of it) and strikes it: the fight begins.
    void pull(Creature c, float distance = 3)
    {
        import std.math : cos, sin;

        const at = c.position;
        goTo(Position(at.x + distance * cos(at.orientation), at.y + distance * sin(at.orientation), at.z));
        hit(c, 1);
    }

    /// Character `i` deals `amount` to `c` (a spell's blow): its threat, its script's `Damaged`.
    void hit(Creature c, uint amount, size_t i = 0)
    {
        dealDamage(unit(i), map.unitOf(c), amount, Blow.spell());
    }

    /// `c` hurt down to `percent` of its health, a twentieth at a time with `between` of the fight after each.
    void hurtTo(Creature c, uint percent, Duration between = 300.msecs)
    {
        const maximum = c.values.get!UNIT_FIELD_MAXHEALTH;
        const goal = cast(uint)(ulong(maximum) * percent / 100);
        const chunk = maximum / 20 + 1;
        foreach (_; 0 .. 200)
        {
            const health = c.values.get!UNIT_FIELD_HEALTH;
            if (!c.alive || health <= goal)
                break;
            hit(c, health - goal < chunk ? health - goal : chunk);
            run(between);
        }
    }

    /// `c` killed by the party's leader (its kill: credit and loot).
    void kill(Creature c)
    {
        if (c.alive)
            hit(c, c.values.get!UNIT_FIELD_HEALTH);
        run(200.msecs);
    }

    /// The leader keeps within `within` yards of `c` (an escort walked with): moved beside it when farther.
    void keepUp(Creature c, float within = 10)
    {
        if (c is null)
            return;
        const at = c.position, me = player.position;
        if (((me.x - at.x) ^^ 2 + (me.y - at.y) ^^ 2 + (me.z - at.z) ^^ 2) > within ^^ 2)
            goTo(Position(at.x + 1, at.y, at.z));
    }

    /// Every living creature summoned while the test watched (of `entries`; any if none) killed by the leader; how
    /// many.
    size_t killSummons(const(uint)[] entries = null)
    {
        size_t n;
        foreach (s; summons)
            if (entries.length == 0 || entries.canFind(s.entry))
                if (auto c = cast(Creature) map.findObject(s.guid))
                    if (c.alive)
                    {
                        hit(c, c.values.get!UNIT_FIELD_HEALTH);
                        ++n;
                    }
        return n;
    }

    /// Every creature fighting `c` (or the party) killed by the leader, as a party defends an escort; how many.
    size_t defend(Creature c)
    {
        Creature[] foes;
        map.forEachObject((MapObject o) {
            if (auto other = cast(Creature) o)
                if (other.alive && other !is c && other.ai !is null && other.ai.inCombat)
                {
                    const victim = other.ai.currentVictim;
                    if (victim == c.guid || victim == player.guid)
                        foes ~= other;
                }
        });
        foreach (foe; foes)
            hit(foe, foe.values.get!UNIT_FIELD_HEALTH);
        return foes.length;
    }

    /// The party dies (`keepAlive` off): what fought it goes home.
    void wipe(Duration after = 15.seconds)
    {
        keepAlive = false;
        godlike();
        foreach (i; 0 .. party.length)
            if (player(i).values.get!UNIT_FIELD_HEALTH)
                dealDamage(UnitRef.init, unit(i), player(i).values.get!UNIT_FIELD_HEALTH, Blow.spell());
        run(after);
    }

    /// The dead party resurrected where it lies, kept alive again.
    void revive()
    {
        import dmangos.bytes : ByteWriter;

        foreach (i, ref c; party)
        {
            auto me = c.session.inWorld;
            me.resurrectRequested(1, mapId, player(i).position, player(i).values.get!UNIT_FIELD_MAXHEALTH, 0, false);
            ByteWriter b;
            b.put(ulong(1));
            b.put(ubyte(1));
            c.write(Opcode.CMSG_RESURRECT_RESPONSE, b.data.dup);
        }
        keepAlive = true;
        run(200.msecs);
    }

    /// The world's tick, `step` at a time, for `time`; what the client is told is collected.
    void run(Duration time, Duration step = 100.msecs)
    {
        for (Duration done; done < time; done += step)
            tick(step);
    }

    /// Runs until `until` holds (true) or `limit` passes (false).
    bool runUntil(scope bool delegate() until, Duration limit, Duration step = 100.msecs)
    {
        for (Duration done; done < limit; done += step)
        {
            if (until())
                return true;
            tick(step);
        }
        return until();
    }

    /// The party takes no damage (`.cheat god`) while `keepAlive`, its health and mana full.
    private void godlike()
    {
        foreach (i, ref c; party)
        {
            auto me = c.session.inWorld;
            if (me is null || me.player is null)
                continue;
            me.godModeCheat = keepAlive;
            auto p = me.player;
            if (keepAlive && p.values.get!UNIT_FIELD_HEALTH)
            {
                p.values.set!UNIT_FIELD_HEALTH(p.values.get!UNIT_FIELD_MAXHEALTH);
                p.values.set!UNIT_FIELD_POWER1(0, p.values.get!UNIT_FIELD_MAXPOWER1(0));
            }
        }
    }

    private void tick(Duration step)
    {
        w.now += step;
        w.context.update(w.now);
        godlike();
        collect();
    }

    /// Reads what the party was told: the leader's lines and casts, and the creatures summoned since.
    void collect()
    {
        foreach (i, ref c; party)
        {
            auto packets = c.read();
            if (i)
                continue;
            foreach (p; packets)
            {
                auto r = ByteReader(p.body_);
                if (p.opcode == Opcode.SMSG_MESSAGECHAT)
                {
                    const type = cast(ChatType) r.read!ubyte;
                    with (ChatType) if (!(type == CHAT_MSG_MONSTER_SAY || type == CHAT_MSG_MONSTER_YELL
                            || type == CHAT_MSG_MONSTER_EMOTE || type == CHAT_MSG_RAID_BOSS_EMOTE
                            || type == CHAT_MSG_MONSTER_WHISPER || type == CHAT_MSG_RAID_BOSS_WHISPER))
                        continue;
                    r.read!uint; // language
                    ulong speaker;
                    if (type == ChatType.CHAT_MSG_MONSTER_SAY || type == ChatType.CHAT_MSG_MONSTER_YELL)
                        speaker = r.read!ulong;
                    const nameLength = r.read!uint;
                    const name = cast(string) r.readBytes(nameLength)[0 .. $ - 1].idup;
                    r.read!ulong;
                    const textLength = r.read!uint;
                    const text = cast(string) r.readBytes(textLength)[0 .. $ - 1].idup;
                    said ~= Said(type, speaker, name, text);
                    if (trace)
                        imported!"std.stdio".stderr.writefln("  [%s] %s %s: %s", (w.now - started).total!"msecs", type, name, text);
                }
                else if (p.opcode == Opcode.SMSG_SPELL_START || p.opcode == Opcode.SMSG_SPELL_GO)
                {
                    r.readPackedGuid();
                    const caster = r.readPackedGuid();
                    const spell = r.read!uint;
                    casts ~= Cast(caster, entryOfGuid(caster), spell, p.opcode == Opcode.SMSG_SPELL_START);
                    if (trace)
                        imported!"std.stdio".stderr.writefln("  [%s] cast by %s: %s%s", (w.now - started).total!"msecs", entryOfGuid(caster), spell, p.opcode == Opcode.SMSG_SPELL_START ? " (starts)" : "");
                }
            }
        }
        map.forEachObject((MapObject o) {
            if (auto c = cast(Creature) o)
                if (c.guid !in known)
                {
                    known[c.guid] = true;
                    if (c.summon.type != TempSpawnType.none)
                    {
                        summons ~= Summon(c.guid, c.template_.entry, c.summon.summoner);
                        if (trace)
                            imported!"std.stdio".stderr.writefln("  [%s] summoned %s at %s", (w.now - started).total!"msecs",
                                c.template_.entry, c.position);
                    }
                }
        });
    }

    /// Forgets what was collected (the lines, casts and summons so far).
    void forget()
    {
        collect();
        said = null;
        casts = null;
        summons = null;
    }

    // What the client was told

    /// The text `entry`: a `script_texts` row (negative) or a `broadcast_text` row.
    private const(imported!"dmangos.world.npcdata".BroadcastText)* line(long entry)
    {
        const t = entry < 0 ? w.context.scriptText(cast(int) entry) : w.context.broadcastText(cast(uint) entry);
        assert(t !is null, format!"no text %s"(entry));
        return t;
    }

    /// The text of `script_texts` row `entry` (negative) or `broadcast_text` row `entry` (its male text).
    string textOf(long entry)
    {
        return line(entry).text(false);
    }

    /// Whether the client heard the text `entry` (a `script_texts` row, negative, or a `broadcast_text` row).
    bool heard(long entry)
    {
        const t = line(entry);
        const male = t.text(false), female = t.text(true);
        foreach (s; said)
            if (s.text == male || s.text == female)
                return true;
        return false;
    }

    /// How many times the client heard the text `entry`.
    size_t timesHeard(long entry)
    {
        const male = textOf(entry);
        size_t n;
        foreach (s; said)
            n += s.text == male;
        return n;
    }

    /// Whether a creature of `entry` (0: any) cast `spell` (started or went).
    bool cast_(uint spell, uint entry = 0)
    {
        foreach (c; casts)
            if (c.spell == spell && (entry == 0 || c.entry == entry))
                return true;
        return false;
    }

    /// How many times a creature of `entry` (0: any) cast `spell` (its `SMSG_SPELL_GO`s).
    size_t timesCast(uint spell, uint entry = 0)
    {
        size_t n;
        foreach (c; casts)
            n += !c.started && c.spell == spell && (entry == 0 || c.entry == entry);
        return n;
    }

    /// The spells creatures of `entry` cast (went), each once, in order.
    uint[] spellsOf(uint entry)
    {
        uint[] got;
        foreach (c; casts)
            if (c.entry == entry && !c.started && !got.canFind(c.spell))
                got ~= c.spell;
        return got;
    }

    /// How many creatures of `entry` were summoned.
    size_t summoned(uint entry)
    {
        size_t n;
        foreach (s; summons)
            n += s.entry == entry;
        return n;
    }

    /// Whether the door (game object) `go` is open.
    static bool isOpen(const GameObject go)
    {
        import dmangos.world.gameobject : goStateActive;

        return go.goState == goStateActive;
    }

    /// What was collected, for an assertion's message.
    string story()
    {
        import std.array : appender;

        auto s = appender!string;
        foreach (x; said)
            s ~= format!"  said %s: %s\n"(x.name, x.text);
        uint[2][] seen;
        foreach (c; casts)
            if (!c.started && !seen.canFind([c.entry, c.spell]))
                seen ~= [c.entry, c.spell];
        foreach (c; seen)
            s ~= format!"  cast by %s: %s\n"(c[0], c[1]);
        foreach (x; summons)
            s ~= format!"  summoned %s\n"(x.entry);
        return s[];
    }

    // The copy saved and loaded

    /**
     * The server restarts: a new world on the same (in-memory) databases, the party logged in again (character
     * `i` each, where it was) and back in this copy: its script made anew from the saved `instance.data`.
     */
    void restart()
    {
        reconnect(false);
    }

    /// Discards the old world without letting its sockets log out or its timers run.
    void restartAfterCrash()
    {
        reconnect(false, true);
    }

    /// Moves the dungeon's region to a second world and reconnects the party to the transferred copy.
    void handoff()
    {
        reconnect(true);
    }

    private void reconnect(bool handoff, bool crash = false)
    {
        import dmangos.cluster.regions : Region;
        import dmangos.world.config : WorldConfig;
        import dmangos.world.context : WorldContext;

        const copy = instanceId;
        Position[] where;
        foreach (i; 0 .. party.length)
            where ~= player(i).position;
        WorldConfig config;
        config.logoutDelay = 0;
        auto old = w.context;
        if (handoff)
        {
            w.context = new WorldContext(config, w.db, old.data, old.client);
            enum uint regionId = 40;
            if (old.nodeId == 0)
                old.nodeId = 1;
            const next = cast(ushort)(old.nodeId == 1 ? 2 : 1);
            w.context.nodeId = next;
            old.regionOwnerAround = w.context.regionOwnerAround = (uint, Position, float) => next;
            Region moving = Region(regionId, mapId);
            moving.next = next;
            ubyte[][uint] leaving;
            old.regionsChanged(null, [moving], null, leaving);
            const(ubyte)[][uint] arriving;
            arriving[regionId] = leaving[regionId];
            w.context.regionsChanged([Region(regionId, mapId)], null, arriving, leaving);
            assert(w.context.instanceMap(copy) !is null, "the copy arrived");
        }
        if (!crash)
        {
            foreach (ref c; party)
                c.write(Opcode.CMSG_LOGOUT_REQUEST, null);
            w.now += 100.msecs;
            old.update(w.now);
        }
        if (handoff)
        {
            assert(old.instanceState(copy) is null, "the previous owner dropped the copy");
            w.context.clock = () => w.now;
            w.context.update(w.now); // the new owner can tick before the players arrive
        }
        else
            w.context = new WorldContext(config, w.db, old.data, old.client);
        {
            import std.random : rndGen;

            w.context.map(0).random.seed(20_261_120);
            rndGen.seed(20_261_120);
        }
        party = null;
        if (!handoff)
            known = null;
        foreach (i, at; where)
        {
            party ~= w.character(cast(uint)(i + 1), format!"Delver%s"(cast(char)('a' + i)), classId, level, []);
            port(party[$ - 1], mapId, at, copy);
        }
        assert(party[0].session.inWorld.instanceId == copy, "back in the same copy");
        map.random.seed(20_261_120);
        run(500.msecs);
    }
}
