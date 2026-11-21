/**
 * For the tests of the zone scripts: a creature host that records what its script does (`log`, one
 * line per action), walks an escort path of as many points as a test gives it, and answers queries
 * as the test sets them; and a driver that raises events at a script and ticks it.
 */
module dmangos.scripts.testhost;

version (unittest):

import std.conv : to;
import dmangos.script;
import dmangos.script.registry : ScriptHandle, ScriptKind, ScriptRuntime;

/// See the module documentation.
final class TestCreature : CreatureHost
{
    string[] log;                 /// "say -1000101", "text 25", "event 155", "summon 2776", ...
    EntityRef me = EntityRef(0xF130_0000_0100_0001);
    EntityRef player = EntityRef(7);
    size_t pathLength = 10;       /// points of its escort path
    bool fighting;
    bool walking;
    uint lastPoint = uint.max;    /// the point of its last `moveTo`
    float distance = 5;           /// to anyone
    bool playerAlive = true;
    QuestProgress progress = QuestProgress.incomplete;
    QuestProgress[uint] questProgress; /// of some quests (others: `progress`)
    EntityRef[uint] nearby;       /// creatures (and objects) near it, by entry
    uint summons;
    uint health = 100;
    uint faction;
    uint randomValue;             /// what `random` answers (below its bound)

    private void note(T...)(string what, T args)
    {
        string line = what;
        foreach (a; args)
            line ~= " " ~ a.to!string;
        log ~= line;
    }

    /// Whether `line` was logged.
    bool did(string line) const
    {
        foreach (l; log)
            if (l == line)
                return true;
        return false;
    }

    EntityRef hostSelf() { return me; }
    EntityRef hostVictim() { return fighting ? player : EntityRef.init; }
    uint hostHealthPercent() { return health; }
    bool hostInCombat() { return fighting; }
    Location hostLocation() { return Location(1, 2, 3); }
    uint hostHealthPercentOf(EntityRef) { return 100; }
    ActionResult hostCast(uint spell, EntityRef, bool) { note("cast", spell); return ActionResult.ok; }
    ActionResult hostSay(int entry, EntityRef) { note("say", entry); return ActionResult.ok; }
    void hostEquip(uint a, uint b, uint c) { note("equip", a, b, c); }
    void hostRestoreEquipment() { note("equip back"); }
    void hostStandState(StandState s) { note("stand", cast(uint) s); }
    void hostCombatMovement(bool on) { note("combat movement", on); }
    void hostMelee(bool on) { note("melee", on); }
    EntityRef hostSummon(uint entry, Location, uint, EntityRef)
    {
        note("summon", entry);
        return EntityRef(0xF130_0000_0000_0000 | (ulong(entry) << 24) | ++summons);
    }
    void hostDespawn(uint) { note("despawn"); }
    ActionResult hostSignal(EntityRef to, uint id, int) { note("signal", to.entry, id); return ActionResult.ok; }
    void hostSignalDungeon(uint, int) {}
    void hostLog(string) {}
    void hostMoveTo(Location, uint point, bool run) { walking = true; lastPoint = point; }
    bool hostMoving() { return walking; }
    bool hostWaypoint(size_t i, out Waypoint w)
    {
        if (i >= pathLength)
            return false;
        w = Waypoint(Location(i, 0, 0), 0);
        return true;
    }
    size_t hostWaypointCount() { return pathLength; }
    float hostDistanceTo(EntityRef) { return distance; }
    bool hostAlive(EntityRef who) { return who != player || playerAlive; }
    void hostQuestEvent(EntityRef, uint quest) { note("event", quest); }
    void hostFailQuest(EntityRef, uint quest) { note("fail", quest); }
    void hostNpcFlags(uint flags) { note("npc flags", flags); }
    void hostRestoreNpcFlags() { note("npc flags back"); }
    void hostGossipMenu(EntityRef, uint menu) { note("menu", menu); }
    void hostCloseGossip(EntityRef) { note("close gossip"); }
    uint hostRandom(uint below) { return below ? randomValue % below : 0; }
    QuestProgress hostQuestStatus(EntityRef, uint quest) { return questProgress.get(quest, progress); }
    EntityRef hostRandomTarget() { return fighting ? player : EntityRef.init; }
    ActionResult hostSayBroadcast(EntityRef speaker, uint text, EntityRef)
    {
        if (speaker == me)
            note("text", text);
        else
            note("text of", speaker.entry, text);
        return ActionResult.ok;
    }
    void hostEmote(uint emote) { note("emote", emote); }
    EntityRef hostCreatureNearby(uint entry, float) { return nearby.get(entry, EntityRef.init); }
    ActionResult hostDespawnOther(EntityRef c, uint) { note("despawn other", c.entry); return ActionResult.ok; }
    void hostSendGossip(EntityRef, uint textId, const(MenuOption)[] options, bool)
    {
        note("gossip", textId, options.length);
    }

    // Eastern Kingdoms scripts:
    void hostSetFaction(uint f) { faction = f; note("faction", f); }
    void hostUnitFlags(uint flags, bool set) { note(set ? "flags on" : "flags off", flags); }
    void hostReactState(Reaction r) { note("react", cast(uint) r); }
    void hostDeathPrevention(bool on) { note("death prevention", on); }
    void hostEvade() { fighting = false; note("evade"); }
    ActionResult hostAttackBy(EntityRef attacker, EntityRef target)
    {
        note("attack", attacker == me ? 0 : attacker.entry, target == player ? 0 : target.entry);
        return ActionResult.ok;
    }
    ActionResult hostMoveOther(EntityRef c, Location, uint point, bool) { note("move other", c.entry, point); return ActionResult.ok; }
    void hostFace(EntityRef) { note("face"); }
    void hostSheath(Sheath s) { note("sheath", cast(uint) s); }
    void hostMount(uint display) { note("mount", display); }
    void hostDie() { note("die"); }
    bool hostChangeEntry(uint entry) { note("entry", entry); return true; }
    EntityRef hostObjectNearby(uint entry, float) { return nearby.get(entry, EntityRef.init); }
    ActionResult hostUseObject(EntityRef o) { note("use", o.entry); return ActionResult.ok; }
    ActionResult hostRemoveAura(EntityRef, uint spell) { note("unaura", spell); return ActionResult.ok; }
    bool hostHasAura(EntityRef, uint) { return false; }
    ActionResult hostSayOther(EntityRef speaker, int entry, EntityRef)
    {
        note("say of", speaker.entry, entry);
        return ActionResult.ok;
    }
    void hostMovementScript(uint id) { note("movement script", id); }
    void hostRelay(int id, EntityRef) { note("relay", id); }
    void hostKillCredit(EntityRef, uint entry) { note("credit", entry); }
    // Kalimdor scripts:
    ActionResult hostFactionOf(EntityRef c, uint f) { note("faction of", c.entry, f); return ActionResult.ok; }
    ActionResult hostUnitFlagsOf(EntityRef c, uint flags, bool) { note("flags of", c.entry, flags); return ActionResult.ok; }
    void hostFollow(EntityRef leader, float, float) { note(leader ? "follow" : "unfollow"); }
    ActionResult hostCastAs(EntityRef c, uint spell, EntityRef, bool) { note("cast as", c.entry, spell); return ActionResult.ok; }
    ActionResult hostObjectUsable(EntityRef, bool) { return ActionResult.ok; }
    uint hostEntryOf(EntityRef who) { return who.entry; }
    void hostGroupQuestEvent(EntityRef, uint quest) { note("group event", quest); }
    bool hostLocationOf(EntityRef, out Location) { return false; }
    void hostEmoteState(uint emote) { note("emote state", emote); }
    size_t hostCreaturesNearby(uint, float, EntityRef[]) { return 0; }
    EntityRef hostOwner() { return EntityRef.init; }
    uint hostItemCount(EntityRef, uint) { return 0; }
    uint hostGiveItem(EntityRef, uint, uint) { return 0; }
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
    float hostThreatOf(EntityRef) { return 0; }

    // Open-world round 2:
    uint hostLevelOf(EntityRef) { return 0; }
    uint hostSkillOf(EntityRef, uint) { return 0; }
    bool hostKnowsSpell(EntityRef, uint) { return false; }
    Standing hostStandingOf(EntityRef, uint) { return Standing.neutral; }
    bool hostWearsItemNeeding(EntityRef, uint) { return false; }
    bool hostTakeMoney(EntityRef, uint) { return false; }
    void hostUnlearnSpell(EntityRef, uint) {}
    void hostOpenWindow(EntityRef, NpcWindow) {}
    void hostZoneUnderAttack(EntityRef) {}
    void hostWalkPath(uint pathId) {}
    ActionResult hostSendHome(EntityRef) { return ActionResult.ok; }
    void hostWarEffortHandIn(uint, uint) {}
    void hostWarEffortColossus(uint) {}
}

/// A script under test: the runtime of `Module`, one creature's script, and its host.
struct Driven(alias Module)
{
    ScriptRuntime runtime;
    ScriptHandle handle;
    TestCreature host;

    /// The script serving `name` in `Module`, on a fresh host.
    static Driven make(string name)
    {
        Driven d;
        d.runtime = ScriptRuntime.of!Module();
        d.handle = d.runtime.create(ScriptKind.creature, name);
        assert(d.handle, name ~ " is not served");
        d.host = new TestCreature;
        return d;
    }

    /// Raises `event`.
    void raise(E)(E event)
    {
        auto me = CreatureContext(host);
        runtime.raise(handle, me, event);
    }

    /// `ms` milliseconds pass, in steps of 100.
    void tick(int ms)
    {
        auto me = CreatureContext(host);
        for (int left = ms; left > 0; left -= 100)
            runtime.tick(handle, me, left < 100 ? left : 100);
    }

    /// Its escort arrives wherever it was walking, and waits there `ms`: the point reached (0-based).
    uint arrive(int ms = 100)
    {
        const point = host.lastPoint;
        host.walking = false;
        host.lastPoint = uint.max;
        raise(MovementDone(point));
        tick(ms);
        return point;
    }

    /// Walks its escort on until it stops moving on (paused, finished or failed), or reaches `until`
    /// (0-based), `ms` passing at each point.
    void walk(uint until = uint.max, int ms = 60_000)
    {
        foreach (_; 0 .. 1000)
        {
            if (host.lastPoint == uint.max)
                return;
            const point = arrive(ms);
            if (point == until)
                return;
        }
    }
}

/// A creature of `entry` (its guid's `low` part).
EntityRef creatureRef(uint entry, uint low = 1)
{
    return EntityRef(0xF130_0000_0000_0000 | (ulong(entry) << 24) | low);
}
