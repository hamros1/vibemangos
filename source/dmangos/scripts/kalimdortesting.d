/**
 * What the Kalimdor scripts' tests drive them with: a creature host that writes down what its
 * script does ("say -1000370", "summon 3925", "event 898"), with an escort path, a player at a
 * distance, quests and creatures nearby as a test sets them; and a runner that walks an escort.
 */
module dmangos.scripts.kalimdortesting;

version (unittest):

import std.conv : to;

import dmangos.script;
import dmangos.script.registry : ScriptHandle, ScriptKind, ScriptRuntime;

/// A player for the tests.
enum EntityRef hero = EntityRef(7);

/// A creature's guid for `entry` (spawn `low`).
EntityRef creatureRef(uint entry, uint low = 1)
{
    return EntityRef(0xF130_0000_0000_0000UL | (cast(ulong) entry << 24) | low);
}

/// See the module documentation.
final class RecordingCreature : CreatureHost
{
    EntityRef self_;
    Waypoint[] path;
    string[] did;               /// what the script did, in order
    float distance = 5;         /// to anyone
    bool playerAlive = true;
    bool fighting;
    bool walking;
    uint health = 100;
    QuestProgress[uint] quests;
    EntityRef[uint] nearby;     /// creatureNearby, by entry
    EntityRef[uint] objects;    /// objectNearby, by entry
    bool[uint] auras;
    uint randomValue;
    uint summons;
    EntityRef[] summoned;       /// what it summoned, in order

    this(uint entry, size_t points = 0)
    {
        self_ = creatureRef(entry);
        foreach (i; 0 .. points)
            path ~= Waypoint(Location(i, 0, 0));
    }

    /// Whether it did `what`.
    bool has(string what) const
    {
        foreach (d; did)
            if (d == what)
                return true;
        return false;
    }

    private void note(string what) { did ~= what; }

    EntityRef hostSelf() { return self_; }
    EntityRef hostVictim() { return fighting ? hero : EntityRef.init; }
    uint hostHealthPercent() { return health; }
    bool hostInCombat() { return fighting; }
    Location hostLocation() { return Location(1, 2, 3); }
    uint hostHealthPercentOf(EntityRef) { return 100; }
    ActionResult hostCast(uint spell, EntityRef, bool) { note("cast " ~ spell.to!string); return ActionResult.ok; }
    ActionResult hostSay(int entry, EntityRef) { note("say " ~ entry.to!string); return ActionResult.ok; }
    void hostEquip(uint, uint, uint) {}
    void hostRestoreEquipment() {}
    void hostStandState(StandState s) { note("stand " ~ (cast(uint) s).to!string); }
    void hostCombatMovement(bool) {}
    void hostMelee(bool) {}
    EntityRef hostSummon(uint entry, Location, uint, EntityRef)
    {
        note("summon " ~ entry.to!string);
        summoned ~= creatureRef(entry, 100 + ++summons);
        return summoned[$ - 1];
    }
    void hostDespawn(uint) { note("despawn"); }
    ActionResult hostSignal(EntityRef, uint id, int) { note("signal " ~ id.to!string); return ActionResult.ok; }
    void hostSignalDungeon(uint, int) {}
    void hostLog(string) {}
    void hostMoveTo(Location at, uint point, bool) { note("move " ~ point.to!string); walking = true; }
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
    bool hostAlive(EntityRef who) { return who != hero || playerAlive; }
    void hostQuestEvent(EntityRef, uint quest) { note("event " ~ quest.to!string); }
    void hostFailQuest(EntityRef, uint quest) { note("fail " ~ quest.to!string); }
    void hostNpcFlags(uint flags) { note("npcflags " ~ flags.to!string); }
    void hostRestoreNpcFlags() { note("npcflags restored"); }
    void hostGossipMenu(EntityRef, uint menu) { note("menu " ~ menu.to!string); }
    void hostCloseGossip(EntityRef) { note("close"); }
    uint hostRandom(uint below) { return below ? randomValue % below : 0; }
    QuestProgress hostQuestStatus(EntityRef, uint quest) { return quests.get(quest, QuestProgress.none); }
    EntityRef hostRandomTarget() { return fighting ? hero : EntityRef.init; }
    ActionResult hostSayBroadcast(EntityRef speaker, uint text, EntityRef)
    {
        note((speaker == self_ ? "text " : "text as " ~ speaker.entry.to!string ~ " ") ~ text.to!string);
        return ActionResult.ok;
    }
    void hostEmote(uint emote) { note("emote " ~ emote.to!string); }
    EntityRef hostCreatureNearby(uint entry, float) { return nearby.get(entry, EntityRef.init); }
    ActionResult hostDespawnOther(EntityRef c, uint) { note("despawn " ~ c.entry.to!string); return ActionResult.ok; }
    void hostSendGossip(EntityRef, uint textId, const(MenuOption)[] options, bool)
    {
        note("gossip " ~ textId.to!string ~ " " ~ options.length.to!string);
    }
    // Eastern Kingdoms scripts' part of the host:
    void hostSetFaction(uint faction) { note("faction " ~ faction.to!string); }
    void hostUnitFlags(uint flags, bool set) { note((set ? "flags+ " : "flags- ") ~ flags.to!string); }
    void hostReactState(Reaction state) { note(state == Reaction.passive ? "passive" : "not passive"); }
    void hostDeathPrevention(bool on) { note(on ? "immortal" : "mortal"); }
    void hostEvade() { note("evade"); }
    ActionResult hostAttackBy(EntityRef c, EntityRef victim)
    {
        note("attack " ~ c.entry.to!string ~ " " ~ (victim == hero ? "hero" : victim.entry.to!string));
        return ActionResult.ok;
    }
    ActionResult hostMoveOther(EntityRef c, Location, uint point, bool)
    {
        note("move " ~ c.entry.to!string ~ " " ~ point.to!string);
        return ActionResult.ok;
    }
    void hostFace(EntityRef) {}
    void hostSheath(Sheath) {}
    void hostMount(uint display) { note("mount " ~ display.to!string); }
    void hostDie() { note("die"); }
    bool hostChangeEntry(uint entry) { note("entry " ~ entry.to!string); return true; }
    EntityRef hostObjectNearby(uint entry, float) { return objects.get(entry, EntityRef.init); }
    ActionResult hostUseObject(EntityRef o) { note("use " ~ o.entry.to!string); return ActionResult.ok; }
    ActionResult hostRemoveAura(EntityRef, uint spell) { note("unaura " ~ spell.to!string); auras.remove(spell); return ActionResult.ok; }
    bool hostHasAura(EntityRef, uint spell) { return auras.get(spell, false); }
    ActionResult hostSayOther(EntityRef c, int entry, EntityRef)
    {
        note("say as " ~ c.entry.to!string ~ " " ~ entry.to!string);
        return ActionResult.ok;
    }
    void hostMovementScript(uint id) { note("script " ~ id.to!string); }
    void hostRelay(int id, EntityRef) { note("relay " ~ id.to!string); }
    void hostKillCredit(EntityRef, uint entry) { note("credit " ~ entry.to!string); }

    // Kalimdor scripts' part:
    ActionResult hostFactionOf(EntityRef c, uint faction)
    {
        note("faction of " ~ c.entry.to!string ~ " " ~ faction.to!string);
        return ActionResult.ok;
    }
    ActionResult hostUnitFlagsOf(EntityRef, uint flags, bool set)
    {
        note((set ? "flags+ " : "flags- ") ~ flags.to!string);
        return ActionResult.ok;
    }
    void hostFollow(EntityRef leader, float, float) { note(leader ? "follow" : "unfollow"); }
    ActionResult hostCastAs(EntityRef c, uint spell, EntityRef, bool)
    {
        note("cast as " ~ c.entry.to!string ~ " " ~ spell.to!string);
        return ActionResult.ok;
    }
    ActionResult hostObjectUsable(EntityRef, bool usable) { note(usable ? "usable" : "unusable"); return ActionResult.ok; }
    uint hostEntryOf(EntityRef who) { return who.entry; }
    void hostGroupQuestEvent(EntityRef, uint quest) { note("event " ~ quest.to!string); }
    bool hostLocationOf(EntityRef who, out Location at)
    {
        at = Location(10, 20, 30);
        return cast(bool) who;
    }
    void hostEmoteState(uint emote) { note("emote state " ~ emote.to!string); }
    size_t hostCreaturesNearby(uint entry, float, EntityRef[] found)
    {
        if (found.length == 0 || entry !in nearby)
            return 0;
        found[0] = nearby[entry];
        return 1;
    }
    EntityRef owner_;
    EntityRef hostOwner() { return owner_; }
    uint[uint] items;           /// the hero's
    uint hostItemCount(EntityRef, uint item) { return items.get(item, 0); }
    uint hostGiveItem(EntityRef, uint item, uint count)
    {
        note("give " ~ item.to!string);
        items[item] = items.get(item, 0) + count;
        return count;
    }
    // Dungeon scripts:
    EntityRef hostPlayerNearby(float) { return EntityRef.init; }

    // Raid scripts:
    int hostAskDungeon(uint) { return 0; }
    EntityRef hostSelectTarget(Pick, uint, uint) { return EntityRef.init; }
    size_t hostThreatList(EntityRef[]) { return 0; }
    ActionResult hostModifyThreat(EntityRef, int) { return ActionResult.ok; }
    size_t hostPlayersNear(float, EntityRef[]) { return 0; }
    void hostTeleport(Location) {}
    void hostZoneCombat() {}
    bool hostCasting() { return false; }
    void hostInterrupt() {}
    void hostFlying(bool) {}
    void hostDisplay(uint) {}
    void hostSetHealthPercent(EntityRef, uint) {}
    void hostRooted(bool) {}
    void hostAddThreat(EntityRef, float) {}
    void hostMoveNow(Location, uint, bool) {}
    void hostSpellList(uint) {}
    ubyte hostClassOf(EntityRef) { return 0; }

    // Instance round 2:
    ActionResult hostTeleportPlayer(EntityRef, Location) { return ActionResult.ok; }
    ActionResult hostMovementScriptOf(EntityRef, uint) { return ActionResult.ok; }
}

/// A script of `Module` on a recording creature, and the means to drive it.
struct Driven(alias Module)
{
    ScriptRuntime runtime;
    ScriptHandle handle;
    RecordingCreature host;

    this(string name, uint entry, size_t points = 0)
    {
        runtime = ScriptRuntime.of!Module();
        host = new RecordingCreature(entry, points);
        handle = runtime.create(ScriptKind.creature, name);
        assert(handle, name ~ " is not served");
    }

    /// Raises `event`; whether the script consumed it.
    bool raise(E)(E event)
    {
        auto me = CreatureContext(host);
        runtime.raise(handle, me, event);
        return me.consumed;
    }

    /// `ms` milliseconds pass, in ticks of 100.
    void run(int ms)
    {
        auto me = CreatureContext(host);
        for (; ms > 0; ms -= 100)
            runtime.tick(handle, me, 100);
    }

    /// Walks its escort path from where it is to point `last` (arriving at each, waiting a tick).
    void walkTo(uint last)
    {
        foreach (point; 0 .. last + 1)
        {
            if (!host.has("move " ~ point.to!string))
                continue;
            if (host.has("arrived " ~ point.to!string))
                continue;
            host.walking = false;
            host.did ~= "arrived " ~ point.to!string;
            raise(MovementDone(point));
            run(100);
        }
    }

    /// Whether it still has something to do.
    @property bool busy()
    {
        return runtime.busy(handle);
    }
}

/// A game object host that writes down what its script does.
final class RecordingObject : GameObjectHost
{
    EntityRef self_;
    string[] did;
    QuestProgress[uint] quests;
    EntityRef[uint] nearby;

    this(uint entry)
    {
        self_ = EntityRef(0xF110_0000_0000_0000UL | (cast(ulong) entry << 24) | 1);
    }

    bool has(string what) const
    {
        foreach (d; did)
            if (d == what)
                return true;
        return false;
    }

    EntityRef hostSelf() { return self_; }
    void hostDoor(bool open) { did ~= open ? "open" : "close"; }
    void hostSignalDungeon(uint, int) {}
    void hostLog(string) {}
    Location hostObjectLocation() { return Location(1, 2, 3); }
    QuestProgress hostQuestStatus(EntityRef, uint quest) { return quests.get(quest, QuestProgress.none); }
    void hostQuestEvent(EntityRef, uint quest) { did ~= "event " ~ quest.to!string; }
    void hostKillCredit(EntityRef, uint entry) { did ~= "credit " ~ entry.to!string; }
    EntityRef hostSummon(uint entry, Location, uint, EntityRef)
    {
        did ~= "summon " ~ entry.to!string;
        return creatureRef(entry, 100);
    }
    EntityRef hostCreatureNearby(uint entry, float) { return nearby.get(entry, EntityRef.init); }
    ActionResult hostObjectSignal(EntityRef to, uint id, int)
    {
        did ~= "signal " ~ to.entry.to!string ~ " " ~ id.to!string;
        return ActionResult.ok;
    }
    EntityRef hostObjectNearby(uint, float) { return EntityRef.init; }
    ActionResult hostObjectOpen(EntityRef, bool open) { did ~= open ? "open" : "close"; return ActionResult.ok; }
    ActionResult hostObjectFlags(EntityRef, uint flags, bool set)
    {
        did ~= (set ? "flags+ " : "flags- ") ~ flags.to!string;
        return ActionResult.ok;
    }
    ActionResult hostSayAs(EntityRef, uint, EntityRef) { return ActionResult.ok; }
    size_t hostObjectCreaturesNear(uint entry, float, EntityRef[] found)
    {
        if (found.length == 0 || entry !in nearby)
            return 0;
        found[0] = nearby[entry];
        return 1;
    }
    ActionResult hostObjectCast(EntityRef, uint spell, EntityRef)
    {
        did ~= "cast " ~ spell.to!string;
        return ActionResult.ok;
    }

    // Raid scripts:
    int hostAskDungeon(uint) { return 0; }
}

/// `hero` uses game object script `name` of `Module` on `host`; whether the script consumed the use.
bool use(alias Module)(string name, RecordingObject host)
{
    auto runtime = ScriptRuntime.of!Module();
    auto h = runtime.create(ScriptKind.gameObject, name);
    assert(h, name ~ " is not served");
    auto it = GameObjectContext(host);
    runtime.raise(h, it, ObjectUsed(hero));
    return it.consumed;
}
