/**
 * Fakes for the dungeon scripts' unit tests: a creature and a dungeon copy that write down what
 * their scripts asked of them, in words a test can look for ("door 21099 open", "cast 8283"), and
 * runtimes built from one script module.
 */
module dmangos.scripts.testing;

version (unittest):

import std.algorithm.searching : canFind;
import std.format : format;

import dmangos.script;
import dmangos.script.registry : ScriptHandle, ScriptKind, ScriptRuntime;

/// A creature of `entry` (spawn `spawn`), as a guid names it.
EntityRef creatureRef(uint entry, uint spawn = 1)
{
    return EntityRef(0xF130UL << 48 | ulong(entry) << 24 | spawn);
}

/// A game object of `entry` (spawn `spawn`).
EntityRef objectRef(uint entry, uint spawn = 1)
{
    return EntityRef(0xF110UL << 48 | ulong(entry) << 24 | spawn);
}

/// A player.
EntityRef playerRef(uint guid = 7)
{
    return EntityRef(guid);
}

/// What a fake did, and whether it did a thing.
mixin template Recording()
{
    string[] did;

    /// Whether it did `what` (exactly), since the last `forget`.
    bool done(string what) const
    {
        return did.canFind(what);
    }

    /// How many times it did `what`.
    size_t times(string what) const
    {
        size_t n;
        foreach (d; did)
            n += d == what;
        return n;
    }

    /// Starts afresh.
    void forget()
    {
        did = null;
    }
}

/// A creature: see the module documentation.
final class TestCreature : CreatureHost
{
    mixin Recording;
    EntityRef me, victim;
    uint health = 100;
    bool fighting, walking;
    Location at;
    float distance = 5;
    bool othersAlive = true;
    Waypoint[] path;
    EntityRef nearby;     /// what `creatureNearby` finds
    uint randomValue;     /// what `random` answers (below its bound)
    QuestProgress progress;

    this(uint entry = 1)
    {
        me = creatureRef(entry);
        victim = playerRef();
    }

    EntityRef hostSelf() { return me; }
    EntityRef hostVictim() { return victim; }
    uint hostHealthPercent() { return health; }
    bool hostInCombat() { return fighting; }
    Location hostLocation() { return at; }
    uint hostHealthPercentOf(EntityRef) { return 100; }
    ActionResult hostCast(uint spell, EntityRef target, bool) { did ~= format("cast %s", spell); return ActionResult.ok; }
    ActionResult hostSay(int entry, EntityRef) { did ~= format("say %s", entry); return ActionResult.ok; }
    void hostEquip(uint a, uint b, uint c) { did ~= format("equip %s %s %s", a, b, c); }
    void hostRestoreEquipment() { did ~= "restore equipment"; }
    void hostStandState(StandState s) { did ~= format("stand %s", s); }
    void hostCombatMovement(bool on) { did ~= format("combat movement %s", on); }
    void hostMelee(bool on) { did ~= format("melee %s", on); }
    EntityRef hostSummon(uint entry, Location, uint, EntityRef)
    {
        did ~= format("summon %s", entry);
        return creatureRef(entry, cast(uint) did.length + 100);
    }
    void hostDespawn(uint) { did ~= "despawn"; }
    ActionResult hostSignal(EntityRef to, uint id, int value) { did ~= format("signal %s %s", id, value); return ActionResult.ok; }
    void hostSignalDungeon(uint id, int value) { did ~= format("dungeon %s %s", id, value); }
    void hostLog(string) {}
    void hostMoveTo(Location, uint point, bool) { did ~= format("move %s", point); walking = true; }
    bool hostMoving() { return walking; }
    bool hostWaypoint(size_t i, out Waypoint w)
    {
        if (i >= path.length)
            return false;
        w = path[i];
        return true;
    }
    size_t hostWaypointCount() { return path.length; }
    float hostDistanceTo(EntityRef) { return distance; }
    bool hostAlive(EntityRef) { return othersAlive; }
    void hostQuestEvent(EntityRef, uint quest) { did ~= format("quest event %s", quest); }
    void hostFailQuest(EntityRef, uint quest) { did ~= format("quest failed %s", quest); }
    void hostNpcFlags(uint flags) { did ~= format("npc flags %s", flags); }
    void hostRestoreNpcFlags() { did ~= "restore npc flags"; }
    void hostGossipMenu(EntityRef, uint menu) { did ~= format("gossip menu %s", menu); }
    void hostCloseGossip(EntityRef) { did ~= "close gossip"; }
    uint hostRandom(uint below) { return below ? randomValue % below : 0; }
    QuestProgress hostQuestStatus(EntityRef, uint) { return progress; }
    EntityRef hostRandomTarget() { return victim; }
    ActionResult hostSayBroadcast(EntityRef, uint text, EntityRef) { did ~= format("text %s", text); return ActionResult.ok; }
    void hostEmote(uint emote) { did ~= format("emote %s", emote); }
    EntityRef hostCreatureNearby(uint, float) { return nearby; }
    ActionResult hostDespawnOther(EntityRef c, uint) { did ~= format("despawn %s", c.entry); return ActionResult.ok; }
    void hostSendGossip(EntityRef, uint, const(MenuOption)[] options, bool) { did ~= format("gossip %s", options.length); }
    void hostSetFaction(uint faction) { did ~= format("faction %s", faction); }
    void hostUnitFlags(uint set, uint clear) { did ~= format("flags +%x -%x", set, clear); }
    ActionResult hostAttack(EntityRef target) { did ~= "attack"; return ActionResult.ok; }
    void hostRemoveAura(uint spell) { did ~= format("unaura %s", spell); }
    void hostFollow(EntityRef, float, float) { did ~= "follow"; }
    void hostDeathPrevention(bool on) { did ~= format("death prevention %s", on); }
    EntityRef hostPlayerNearby(float) { return victim; }
    bool hostLocate(EntityRef, out Location where) { where = at; return true; }
    bool hostChangeEntry(uint entry) { did ~= format("become %s", entry); return true; }
}

/// A dungeon copy: see the module documentation.
final class TestInstance : InstanceHost
{
    mixin Recording;
    bool[ulong] dead; /// creatures that are not alive
    uint players = 1;
    uint spawned;     /// summons so far (their spawn numbers)

    uint hostMapId() { return 0; }
    uint hostInstanceId() { return 1; }
    ActionResult hostDoor(EntityRef door, bool open)
    {
        did ~= format("door %s %s", door.entry, open ? "open" : "closed");
        return ActionResult.ok;
    }
    ActionResult hostSignal(EntityRef to, uint id, int value)
    {
        did ~= format("signal %s %s %s", to.entry, id, value);
        return ActionResult.ok;
    }
    uint hostPlayerCount() { return players; }
    void hostLog(string) {}
    EntityRef hostSummon(uint entry, Location, uint, EntityRef)
    {
        did ~= format("summon %s", entry);
        return creatureRef(entry, 1000 + ++spawned);
    }
    ActionResult hostSay(EntityRef speaker, int entry, EntityRef)
    {
        did ~= format("say %s %s", speaker.entry, entry);
        return ActionResult.ok;
    }
    ActionResult hostCast(EntityRef caster, uint spell, EntityRef, bool)
    {
        did ~= format("cast %s %s", caster.entry, spell);
        return ActionResult.ok;
    }
    ActionResult hostSetFaction(EntityRef c, uint faction)
    {
        did ~= format("faction %s %s", c.entry, faction);
        return ActionResult.ok;
    }
    ActionResult hostUnitFlags(EntityRef c, uint set, uint clear)
    {
        did ~= format("flags %s +%x -%x", c.entry, set, clear);
        return ActionResult.ok;
    }
    ActionResult hostAttack(EntityRef c, EntityRef)
    {
        did ~= format("attack %s", c.entry);
        return ActionResult.ok;
    }
    ActionResult hostMoveTo(EntityRef c, Location, uint point, bool)
    {
        did ~= format("move %s %s", c.entry, point);
        return ActionResult.ok;
    }
    ActionResult hostDespawn(EntityRef c, uint)
    {
        did ~= format("despawn %s", c.entry);
        return ActionResult.ok;
    }
    bool hostAlive(EntityRef c) { return c && c.guid !in dead; }
    uint hostSpawnObjects(uint entry, uint, Location, float)
    {
        did ~= format("spawn objects %s", entry);
        return 1;
    }
    ActionResult hostObjectFlags(EntityRef o, uint set, uint clear)
    {
        did ~= format("object flags %s +%x -%x", o.entry, set, clear);
        return ActionResult.ok;
    }
    uint hostRandom(uint below) { return 0; }
    ActionResult hostRemoveAura(EntityRef c, uint spell)
    {
        did ~= format("unaura %s %s", c.entry, spell);
        return ActionResult.ok;
    }
    EntityRef fought = EntityRef(7); /// whom every creature fights
    EntityRef hostVictimOf(EntityRef) { return fought; }
    bool hostLocate(EntityRef, out Location at) { return true; }
    EntityRef hostAnyPlayer() { return players ? EntityRef(7) : EntityRef.init; }
    void hostKillCreditAll(uint entry) { did ~= format("credit %s", entry); }
}

/// A script of module `M` with its fake, run as the server runs it (through a `ScriptRuntime`).
struct Running(alias M, Host, Context)
{
    ScriptRuntime runtime;
    ScriptHandle handle;
    Host host;

    /// Raises `event`.
    void raise(E)(E event)
    {
        auto context = Context(host);
        runtime.raise(handle, context, event);
    }

    /// `ms` milliseconds pass, in steps of a quarter second.
    void run(int ms)
    {
        for (int left = ms; left > 0; left -= 250)
        {
            auto context = Context(host);
            runtime.tick(handle, context, left < 250 ? left : 250);
        }
    }

    /// Its state, as saved.
    S state(S)()
    {
        import dmangos.bytes : ByteReader, ByteWriter;
        import dmangos.script.state : loadScript;

        ByteWriter w;
        runtime.save(handle, w);
        S s;
        auto r = ByteReader(w.data);
        assert(loadScript(s, r));
        return s;
    }
}

/// Dungeon script `name` of module `M`, on a fake copy.
Running!(M, TestInstance, InstanceContext) runInstance(alias M)(string name)
{
    Running!(M, TestInstance, InstanceContext) r;
    r.runtime = ScriptRuntime.of!M();
    r.handle = r.runtime.create(ScriptKind.instance, name);
    assert(r.handle, "no dungeon script " ~ name);
    r.host = new TestInstance;
    return r;
}

/// Creature script `name` of module `M`, on a fake creature of `entry`.
Running!(M, TestCreature, CreatureContext) runCreature(alias M)(string name, uint entry = 1)
{
    Running!(M, TestCreature, CreatureContext) r;
    r.runtime = ScriptRuntime.of!M();
    r.handle = r.runtime.create(ScriptKind.creature, name);
    assert(r.handle, "no creature script " ~ name);
    r.host = new TestCreature(entry);
    return r;
}
