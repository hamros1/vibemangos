/**
 * What the raids' and the world's script tests on the real data share (`dmangos.world.realscripts_raids`,
 * `dmangos.world.realscripts_world`): a copy of a raid (or a place on a continent) with characters of the right
 * level in it, its creatures as the world database spawns them, a clock the test turns, and what the first
 * character's client was told: the spells creatures began and cast (`SMSG_SPELL_START`, `SMSG_SPELL_GO`), what they
 * said, yelled and emoted (`SMSG_MESSAGECHAT`), so a test asserts what a player would have seen.
 *
 * The characters may be made god-like (`godlike`): their health is filled at every tick, so a fight runs as long as
 * the test needs. Runs only with the real data (`DMANGOS_REAL_DATA`).
 */
module dmangos.world.realscriptkit_raids;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind, count;
import std.format : format;
import dmangos.bytes : ByteReader;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.gameobject : GameObject;
import dmangos.world.map : Map;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : ChatType, Opcode;
import dmangos.world.player : Player;
import dmangos.world.realspelltests : RealWorld;
import dmangos.world.testclient : TestClient;
import dmangos.world.unit : Blow, dealDamage, UnitRef;
import dmangos.world.updatefields;

enum ubyte classWarrior = 1, classPaladin = 2, classPriest = 5, classMage = 8;

/// A spell a creature (or a player) began or cast, as the client saw it.
struct SeenCast
{
    ulong caster;
    uint spell;
    bool started; /// `SMSG_SPELL_START` (a cast time), else `SMSG_SPELL_GO`
    long atMs;    /// the test's time
}

/// A line a creature said, yelled, emoted or whispered.
struct SeenText
{
    ChatType type;
    string speaker;
    string text;
    long atMs;
}

/// A copy of a raid (or a place on a continent), its characters and what they saw.
final class Scene
{
    RealWorld w;
    uint mapId, instance;
    TestClient[] heroes;
    SeenCast[] casts;
    SeenText[] texts;
    uint[] emotes; /// `SMSG_EMOTE`s of creatures
    long elapsedMs;
    size_t[ushort] opcodes; /// how many of each the first character was sent
    long[2][] deaths; /// the characters who died (a god-like one should not): its guid, when
    bool godlike = true;
    uint seed;

    /**
     * `count` characters of `classId` and `level` at `at` on `mapId`: in a new copy of it if it is a dungeon (all in
     * the same one), on the continent if not. Its creatures load as the characters' sight reaches them.
     */
    this(uint mapId, Position at, size_t count = 1, ubyte classId = classWarrior, uint level = 60, uint seed = 20_261_120)
    {
        ubyte[] classes;
        foreach (k; 0 .. count)
            classes ~= classId;
        this(mapId, at, classes, level, seed);
    }

    /// ditto, a character of each of `classes` (the first a warrior, say, the second a mage: one with mana).
    this(uint mapId, Position at, const(ubyte)[] classes, uint level = 60, uint seed = 20_261_120)
    {
        import dmangos.world.packets : ClientTeleportAck;

        w = RealWorld.make(seed);
        this.mapId = mapId;
        this.seed = seed;
        foreach (k, classId; classes)
        {
            auto hero = w.character(cast(uint)(900 + k), format!"Hero%s"(cast(char)('a' + k)), classId, level, []);
            auto me = hero.session.inWorld;
            auto to = at;
            to.y += k; // a yard apart
            const ok = me.teleportTo(mapId, to, null, k == 0 || instance == 0 ? uint.max : instance, true);
            assert(ok, format!"hero %s not let into map %s"(k, mapId));
            if (mapId == 0)
                hero.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
            else
                hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
            if (k == 0)
            {
                instance = me.instanceId;
                map.random.seed(seed); // the copy's rolls the same at every run
            }
            assert(me.player.data.map == mapId && me.instanceId == instance, "not there");
            hero.read();
            heroes ~= hero;
        }
        fill();
    }

    Map map()
    {
        return w.context.map(mapId, instance);
    }

    Player hero(size_t k = 0)
    {
        return heroes[k].session.inWorld.player;
    }

    UnitRef heroUnit(size_t k = 0)
    {
        return map.unit(hero(k).guid);
    }

    /// Every character at full health (a god-like one's very large).
    void fill()
    {
        foreach (ref h; heroes)
        {
            auto p = h.session.inWorld.player;
            if (!p.alive)
            {
                if (!deaths.canFind!(d => d[0] == p.guid))
                    deaths ~= [p.guid, elapsedMs];
                continue;
            }
            h.session.inWorld.godModeCheat = godlike; // no blow hurts it (a pack's swings in one tick could)
            if (godlike && p.values.get!UNIT_FIELD_MAXHEALTH < 1_000_000)
                p.values.set!UNIT_FIELD_MAXHEALTH(1_000_000);
            p.values.set!UNIT_FIELD_HEALTH(p.values.get!UNIT_FIELD_MAXHEALTH);
        }
    }

    /// The world goes on for `span`, in steps of `step`; what the first character was told is noted.
    void run(Duration span, Duration step = 200.msecs)
    {
        for (Duration done; done < span; done += step)
        {
            w.now += step;
            elapsedMs += step.total!"msecs";
            w.context.update(w.now);
            if (godlike)
                fill();
            listen();
            if (stayWith !is null && stayWith.alive && elapsedMs % 1000 == 0)
                foreach (k; 0 .. heroes.length < following ? heroes.length : following)
                {
                    if (distance(hero(k).position, stayWith.position) > stayWithin)
                        moveHero(k, stayWith.position);
                    // The raid's blows go on (a point each: what a script checks as it is hurt it checks again).
                    if (pressing && stayWith.ai.inCombat && hero(k).alive)
                        dealDamage(heroUnit(k), map.unitOf(stayWith), 1, Blow.spell());
                }
        }
    }

    /// The creature the characters keep close to (players come back to their boss after a fear, a knock back, a
    /// teleport): each moved beside it when it is more than `stayWithin` yards off, every second. null: none.
    Creature stayWith;
    float stayWithin = 10;
    bool pressing = true; /// the characters strike it (a point a second each) while it fights
    size_t following = size_t.max; /// only the first this many keep close (the others are elsewhere)

    /// The distance between two places.
    static float distance(Position a, Position b)
    {
        return ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2) ^^ 0.5f;
    }

    /// Character `k` moved (a teleport on the map) to two yards off `at`.
    void moveHero(size_t k, Position at)
    {
        import dmangos.world.packets : ClientTeleportAck;

        auto me = heroes[k].session.inWorld;
        auto to = at;
        to.x += 2;
        to.y += k;
        me.teleportTo(mapId, to, null, instance, true);
        heroes[k].write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
    }

    /// Runs until `done` holds or `limit` is over; whether it held.
    bool runUntil(scope bool delegate() done, Duration limit, Duration step = 200.msecs)
    {
        for (Duration spent; spent < limit; spent += step)
        {
            if (done())
                return true;
            run(step, step);
        }
        return done();
    }

    /// What the characters' clients were sent since the last time: the first one's noted.
    void listen()
    {
        foreach (k, ref h; heroes)
        {
            auto packets = h.read();
            note(packets, k == 0);
        }
    }

    /// What a character was sent: noted (of the others than the first, only the lines none heard yet).
    void note(const(imported!"dmangos.world.testclient".ServerPacketRead)[] packets, bool first = true)
    {
        {
            foreach (p; packets)
            {
                if (!first && p.opcode != Opcode.SMSG_MESSAGECHAT)
                    continue;
                if (first)
                    opcodes[p.opcode]++;
                auto r = ByteReader(p.body_);
                switch (p.opcode)
                {
                case Opcode.SMSG_SPELL_START, Opcode.SMSG_SPELL_GO:
                    r.readPackedGuid();
                    const caster = r.readPackedGuid();
                    const spell = r.read!uint;
                    casts ~= SeenCast(caster, spell, p.opcode == Opcode.SMSG_SPELL_START, elapsedMs);
                    break;
                case Opcode.SMSG_MESSAGECHAT:
                    const type = cast(ChatType) r.read!ubyte;
                    if (!isMonsterChat(type))
                        break;
                    r.read!uint; // language
                    if (type == ChatType.CHAT_MSG_MONSTER_SAY || type == ChatType.CHAT_MSG_MONSTER_YELL)
                        r.read!ulong;
                    r.read!uint;
                    const name = r.readCString();
                    r.read!ulong;
                    r.read!uint;
                    const line = SeenText(type, name.idup, r.readCString().idup, elapsedMs);
                    if (first || !texts.canFind!(t => t.text == line.text && t.atMs == line.atMs))
                        texts ~= line;
                    break;
                case Opcode.SMSG_EMOTE:
                    emotes ~= r.read!uint;
                    break;
                default:
                    break;
                }
            }
        }
    }

    private static bool isMonsterChat(ChatType t)
    {
        with (ChatType)
            return t == CHAT_MSG_MONSTER_SAY || t == CHAT_MSG_MONSTER_YELL || t == CHAT_MSG_MONSTER_EMOTE
                || t == CHAT_MSG_MONSTER_WHISPER || t == CHAT_MSG_RAID_BOSS_EMOTE || t == CHAT_MSG_RAID_BOSS_WHISPER;
    }

    /// Forgets what was seen so far.
    void forget()
    {
        casts = null;
        texts = null;
        emotes = null;
    }

    // -----------------------------------------------------------------------------------------------------------
    // The creatures
    // -----------------------------------------------------------------------------------------------------------

    /// The creatures of `entry` on the map (in loaded cells), alive ones only unless `dead`.
    Creature[] all(uint entry, bool dead = false)
    {
        Creature[] found;
        foreach (c; map.creaturesNear(hero.position, 100_000))
            if (c.spawn.entry == entry && (dead || c.alive))
                found ~= c;
        return found;
    }

    /// The nearest living creature of `entry` (null: none loaded).
    Creature find(uint entry)
    {
        Creature best;
        float bestDistance = float.max;
        foreach (c; all(entry))
        {
            const d = (c.position.x - hero.position.x) ^^ 2 + (c.position.y - hero.position.y) ^^ 2;
            if (d < bestDistance)
            {
                best = c;
                bestDistance = d;
            }
        }
        return best;
    }

    /// ditto, which must be there.
    Creature the(uint entry, string file = __FILE__, size_t line = __LINE__)
    {
        auto c = find(entry);
        if (c is null)
            throw new Exception(format!"no creature %s on map %s"(entry, mapId), file, line);
        return c;
    }

    /// The game objects of `entry` on the map (in loaded cells).
    GameObject[] objects(uint entry)
    {
        GameObject[] found;
        foreach (o; map.objectsNear(hero.position, 100_000))
            if (auto go = cast(GameObject) o)
                if (go.spawn.entry == entry)
                    found ~= go;
        return found;
    }

    /// A creature of `entry` summoned at `at` (as a script would summon it).
    Creature summon(uint entry, Position at)
    {
        auto c = w.context.summonCreature(map, entry, at, TempSpawnType.manual, 0, 0);
        assert(c !is null, format!"creature %s not summoned"(entry));
        listen();
        return c;
    }

    /// Every character moves to `at` (a teleport on the map), the others a yard apart.
    void moveHeroes(Position at)
    {
        import dmangos.world.packets : ClientTeleportAck;

        foreach (k, ref h; heroes)
        {
            auto me = h.session.inWorld;
            auto to = at;
            to.y += k;
            me.teleportTo(mapId, to, null, instance, true);
            h.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
        }
        listen();
    }

    /// Each character strikes `c` (a little): it fights them.
    void engage(Creature c)
    {
        foreach (k; 0 .. heroes.length)
            dealDamage(heroUnit(k), map.unitOf(c), 1, Blow.spell());
        listen();
    }

    /// `c` hurt by the first character down to `percent` of its health (no lower than 1 point).
    void hurtTo(Creature c, double percent)
    {
        const top = c.values.get!UNIT_FIELD_MAXHEALTH, now = c.values.get!UNIT_FIELD_HEALTH;
        const goal = cast(uint)(top * percent / 100);
        if (now > goal)
            dealDamage(heroUnit, map.unitOf(c), now - (goal ? goal : 1), Blow.spell());
        listen();
    }

    /// `c` killed by the first character.
    void kill(Creature c)
    {
        dealDamage(heroUnit, map.unitOf(c), c.values.get!UNIT_FIELD_HEALTH + 1, Blow.spell());
        listen();
    }

    /// `c`'s health in percent.
    double healthOf(Creature c)
    {
        return 100.0 * c.values.get!UNIT_FIELD_HEALTH / c.values.get!UNIT_FIELD_MAXHEALTH;
    }

    // -----------------------------------------------------------------------------------------------------------
    // What was seen
    // -----------------------------------------------------------------------------------------------------------

    /// Whether `caster` (any caster: 0) began or cast `spell`.
    bool cast_(uint spell, ulong caster = 0)
    {
        return casts.canFind!(c => c.spell == spell && (caster == 0 || c.caster == caster));
    }

    /// How many times `spell` was cast (gone off) by `caster` (any: 0).
    size_t castCount(uint spell, ulong caster = 0)
    {
        return casts.count!(c => c.spell == spell && !c.started && (caster == 0 || c.caster == caster));
    }

    /// Whether a creature of `entry` (on the map, alive or dead) cast `spell`.
    bool castBy(uint entry, uint spell)
    {
        foreach (c; casts)
            if (c.spell == spell)
                if (auto who = map.creatureAt(c.caster))
                    if (who.spawn.entry == entry)
                        return true;
        return false;
    }

    /// The text of `script_texts` entry `id`.
    string textOf(int id)
    {
        auto t = id in w.context.data.scriptTexts;
        assert(t !is null, format!"no script text %s"(id));
        return t.text(false);
    }

    /// Whether the `script_texts` line `id` was said, yelled or emoted.
    bool said(int id)
    {
        import std.algorithm.searching : startsWith;
        import std.string : indexOf;

        const t = textOf(id);
        const dollar = t.indexOf('$'); // a name put in ($n): the text up to it
        return dollar < 0 ? texts.canFind!(s => s.text == t) : texts.canFind!(s => s.text.startsWith(t[0 .. dollar]));
    }

    /// When the line `id` was first said (the test's milliseconds), -1 if it was not.
    long saidAt(int id)
    {
        foreach (s; texts)
            if (s.text == textOf(id))
                return s.atMs;
        return -1;
    }

    /// A summary of what was seen (for a failing assertion's message).
    string seen()
    {
        import std.array : appender;

        auto o = appender!string;
        o ~= "casts:";
        foreach (c; casts)
            if (!c.started)
            {
                const who = map.creatureAt(c.caster);
                o ~= format!" %s@%s(%s)"(c.spell, c.atMs / 1000, who is null ? 0 : who.spawn.entry);
            }
        o ~= "\ntexts:";
        foreach (t; texts)
            o ~= format!" [%s@%s] %s;"(t.speaker, t.atMs / 1000, t.text.length > 40 ? t.text[0 .. 40] : t.text);
        return o.data;
    }

    /**
     * Every creature within `radius` of `center` that one could fight, but those of `keep`, taken off the map (the
     * trash cleared); the unselectable and unattackable (triggers, the scenery's creatures) stay.
     */
    void clear(Position center, float radius, const(uint)[] keep)
    {
        enum uint nonAttackable = 0x2, notSelectable = 0x0200_0000;
        foreach (c; map.creaturesNear(center, radius))
            if (!keep.canFind(c.spawn.entry) && !c.petOwner
                    && !(c.values.get!UNIT_FIELD_FLAGS & (nonAttackable | notSelectable)))
                map.removeObject(c.guid);
        listen();
    }

    /// The copy's script told `id` = `value` (as a creature's or an object's script would tell it).
    void signalCopy(uint id, int value)
    {
        import dmangos.script.api : EntityRef, Signal;

        auto s = w.context.instanceScript(instance);
        assert(s !is null, "the copy has no script");
        s.raise(Signal(EntityRef.init, id, value));
        listen();
    }

    /// The first character speaks to `c` and picks, in turn, the options at `options` of its menus.
    void gossip(Creature c, const(uint)[] options)
    {
        import dmangos.world.packets : ClientGossipSelectOption, ClientNpcGuid;

        heroes[0].write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(c.guid));
        listen();
        foreach (o; options)
        {
            heroes[0].write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(c.guid, o));
            listen();
        }
    }

    /**
     * The copy unloaded and loaded again (its state read back from what it saved): every character goes out to
     * Stormwind, the copy shuts down, and they come back into it where the first stood.
     */
    void reload()
    {
        auto at = hero.position;
        foreach (ref h; heroes)
        {
            h.session.inWorld.teleportTo(0, Position(-8835, 615, 93), null, uint.max, true);
            h.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        }
        run(200.msecs);
        assert(w.context.shutdownInstance(instance), "the copy did not shut down");
        assert(w.context.existingMap(mapId, instance) is null, "the copy is still loaded");
        foreach (k, ref h; heroes)
        {
            auto to = at;
            to.y += k;
            h.session.inWorld.teleportTo(mapId, to, null, instance, true);
            h.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        }
        assert(hero.data.map == mapId && heroes[0].session.inWorld.instanceId == instance, "not back in the copy");
        run(400.msecs);
    }

    /// The first character walks into area trigger `id` (`AreaTrigger.dbc`): moved to its middle, its client says so.
    void enterTrigger(uint id)
    {
        import dmangos.world.packets : ClientTeleportAck;

        const entry = w.context.client.areaTriggers.lookup(id);
        assert(entry !is null && entry.mapId == mapId, format!"no area trigger %s on map %s"(id, mapId));
        auto me = heroes[0].session.inWorld;
        me.teleportTo(mapId, Position(entry.x, entry.y, entry.z), null, instance, true);
        heroes[0].write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
        listen();
        import dmangos.bytes : ByteWriter;

        ByteWriter w;
        w.put(id);
        heroes[0].write(Opcode.CMSG_AREATRIGGER, w.data);
        listen();
    }

    /// Character `k` casts `spell` at `target` at once (triggered: no cast time, no cost), as a stand-in for its
    /// many casts in a fight (a raid's frost on Viscidus).
    void castTriggered(size_t k, uint spell, ulong target)
    {
        heroes[k].session.inWorld.castTriggeredAt(spell, target);
        listen();
    }

    /// Whether the (first) door of `entry` on the map stands open; asserts there is one.
    bool doorOpen(uint entry)
    {
        import dmangos.world.gameobject : goStateActive;

        auto found = objects(entry);
        assert(found.length, format!"no door %s on the map"(entry));
        return found[0].goState == goStateActive;
    }

    /// The first character uses the game object `go` (it must be within reach).
    void use(GameObject go)
    {
        import dmangos.world.packets : ClientGuid;

        heroes[0].write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(go.guid));
        listen();
    }

    /**
     * The first character is given an item of `entry` and uses it at `go` (as a player clicks the item, then the
     * object); the cast's result (`SpellCastResult`, 0: it went), 255 if none came.
     */
    ubyte useItemOn(uint entry, GameObject go)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.defines : inventorySlotBag0;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        auto me = heroes[0].session.inWorld;
        me.storeLoot(entry, 1, 0, false);
        listen();
        ubyte slot = 255;
        foreach (ubyte s; 23 .. 39)
            if (const item = me.player.inventory[inventorySlotBag0, s])
                if (item.entry == entry)
                    slot = s;
        assert(slot != 255, format!"item %s not in the backpack"(entry));
        ByteWriter w;
        w.put(ubyte(inventorySlotBag0));
        w.put(slot);
        w.put(ubyte(1));
        auto targets = SpellTargets(TargetFlags.gameObject);
        targets.gameObject = go.guid;
        targets.write(w);
        heroes[0].write(Opcode.CMSG_USE_ITEM, w.data);
        ubyte result = 255;
        const packets = heroes[0].read();
        foreach (p; packets)
            if (p.opcode == Opcode.SMSG_CAST_RESULT)
            {
                auto r = ByteReader(p.body_);
                r.read!uint;
                result = r.read!ubyte == 0 ? 0 : r.read!ubyte;
            }
        const before = casts.length;
        note(packets);
        if (result == 255 && casts[before .. $].canFind!(c => c.caster == me.player.guid))
            result = 0; // it began (or went): no result is sent for a cast that goes
        return result;
    }

    /// Every character killed by `by` (the god-like no longer): a wipe.
    void wipe(Creature by)
    {
        godlike = false;
        foreach (k, ref h; heroes)
        {
            h.session.inWorld.godModeCheat = false;
            dealDamage(map.unitOf(by), heroUnit(k), hero(k).values.get!UNIT_FIELD_HEALTH + 1, Blow.spell());
        }
        listen();
    }

    /// What the copy's script answers when asked `id` (its `GetData`); int.min without a script.
    int ask(uint id)
    {
        import dmangos.script.api : EntityRef;

        auto s = w.context.instanceScript(instance);
        return s is null ? int.min : s.ask(EntityRef.init, id);
    }

    /// The copy's saved state (`instance.data`).
    string savedData()
    {
        const st = w.context.instanceState(instance);
        return st is null ? null : st.data;
    }
}
