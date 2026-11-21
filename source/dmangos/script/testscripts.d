/**
 * The framework tested on its own, with a fake host: registration, dispatch, schedules, stale
 * handles, persistence, compile-time checks, and dispatch that allocates nothing.
 */
module dmangos.script.testscripts;

version (unittest):

import dmangos.script;
import dmangos.script.registry : problemsOf, ScriptHandle, ScriptKind, ScriptRuntime;

/// A creature that counts what happens to it.
@creature("npc_counter", "npc_counter_alias")
struct Counter
{
    enum Step : ubyte { pulse, shout }
    Schedule!Step steps;
    uint fights, hits, pulses;
    ubyte lastAfter;
    EntityRef enemy;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        ++fights;
        enemy = e.enemy;
        steps.every(Step.pulse, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        ++hits;
        lastAfter = e.after;
        if (e.crossed(50))
            me.castSpell(12_345);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (step == Step.pulse)
            ++pulses;
    }
}

/// A dungeon that remembers who died.
@instance("instance_counter")
struct Dungeon
{
    uint deaths;

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        ++deaths;
    }
}

/// Not a script of this kind: `Damaged` is a creature's event.
struct Wrong
{
    void on(ref InstanceContext copy, const ref Damaged e)
    {
    }
}

/// A schedule whose steps nobody handles.
struct Unhandled
{
    enum Step { a }
    Schedule!Step steps;
}

final class FakeCreature : CreatureHost
{
    uint[] casts;
    EntityRef hostSelf() { return EntityRef(0xF130_0000_0100_0001); }
    EntityRef hostVictim() { return EntityRef(7); }
    uint hostHealthPercent() { return 100; }
    bool fighting;
    bool hostInCombat() { return fighting; }
    Location hostLocation() { return Location.init; }
    uint hostHealthPercentOf(EntityRef) { return uint.max; }
    ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
    ActionResult hostSay(int, EntityRef) { return ActionResult.ok; }
    void hostEquip(uint, uint, uint) {}
    void hostRestoreEquipment() {}
    void hostStandState(StandState) {}
    void hostCombatMovement(bool) {}
    void hostMelee(bool) {}
    EntityRef hostSummon(uint, Location, uint, EntityRef) { return EntityRef.init; }
    void hostDespawn(uint) {}
    ActionResult hostSignal(EntityRef, uint, int) { return ActionResult.notHere; }
    void hostSignalDungeon(uint, int) {}
    void hostLog(string) {}
    Location[] moves;
    bool walking;
    float distance = 5;
    string[] quests;
    void hostMoveTo(Location at, uint, bool) { moves ~= at; walking = true; }
    bool hostMoving() { return walking; }
    bool hostWaypoint(size_t i, out Waypoint w) { if (i >= 3) return false; w = Waypoint(Location(i, 0, 0), i == 1 ? 2000 : 0); return true; }
    size_t hostWaypointCount() { return 3; }
    float hostDistanceTo(EntityRef) { return distance; }
    bool hostAlive(EntityRef) { return true; }
    void hostQuestEvent(EntityRef, uint quest) { quests ~= "event"; }
    void hostFailQuest(EntityRef, uint quest) { quests ~= "failed"; }
    void hostNpcFlags(uint) {}
    void hostRestoreNpcFlags() {}
    void hostGossipMenu(EntityRef, uint) {}
    void hostCloseGossip(EntityRef) {}
    uint hostRandom(uint) { return 0; }
    EntityRef hostRandomTarget() { return EntityRef.init; }
    ActionResult hostSayBroadcast(EntityRef, uint, EntityRef) { return ActionResult.ok; }
    void hostEmote(uint) {}
    EntityRef hostCreatureNearby(uint, float) { return EntityRef.init; }
    ActionResult hostDespawnOther(EntityRef, uint) { return ActionResult.ok; }
    QuestProgress hostQuestStatus(EntityRef, uint) { return QuestProgress.none; }
    void hostSendGossip(EntityRef, uint, const(MenuOption)[], bool) {}

    // Eastern Kingdoms scripts:
    uint faction;
    void hostSetFaction(uint f) { faction = f; }
    void hostUnitFlags(uint, bool) {}
    void hostReactState(Reaction) {}
    void hostDeathPrevention(bool) {}
    void hostEvade() {}
    ActionResult hostAttackBy(EntityRef, EntityRef) { return ActionResult.ok; }
    ActionResult hostMoveOther(EntityRef, Location, uint, bool) { return ActionResult.ok; }
    void hostFace(EntityRef) {}
    void hostSheath(Sheath) {}
    void hostMount(uint) {}
    void hostDie() {}
    bool hostChangeEntry(uint) { return true; }
    EntityRef hostObjectNearby(uint, float) { return EntityRef.init; }
    ActionResult hostUseObject(EntityRef) { return ActionResult.ok; }
    ActionResult hostRemoveAura(EntityRef, uint) { return ActionResult.ok; }
    bool hostHasAura(EntityRef, uint) { return false; }
    ActionResult hostSayOther(EntityRef, int, EntityRef) { return ActionResult.ok; }
    void hostMovementScript(uint) {}
    void hostRelay(int, EntityRef) {}
    // Dungeon scripts:
    EntityRef hostPlayerNearby(float) { return EntityRef.init; }
    void hostKillCredit(EntityRef, uint) {}
    // Kalimdor scripts:
    ActionResult hostFactionOf(EntityRef, uint) { return ActionResult.ok; }
    ActionResult hostUnitFlagsOf(EntityRef, uint, bool) { return ActionResult.ok; }
    void hostFollow(EntityRef, float, float) {}
    ActionResult hostCastAs(EntityRef, uint, EntityRef, bool) { return ActionResult.ok; }
    ActionResult hostObjectUsable(EntityRef, bool) { return ActionResult.ok; }
    uint hostEntryOf(EntityRef) { return 0; }
    void hostGroupQuestEvent(EntityRef, uint quest) { quests ~= "event"; }
    bool hostLocationOf(EntityRef, out Location) { return false; }
    void hostEmoteState(uint) {}
    size_t hostCreaturesNearby(uint, float, EntityRef[]) { return 0; }
    EntityRef hostOwner() { return EntityRef.init; }
    uint hostItemCount(EntityRef, uint) { return 0; }
    uint hostGiveItem(EntityRef, uint, uint) { return 0; }

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

unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;

    alias self = dmangos.script.testscripts;
    auto runtime = ScriptRuntime.of!self();
    assert(runtime.serves(ScriptKind.creature, "npc_counter") && runtime.serves(ScriptKind.creature, "npc_counter_alias"));
    assert(runtime.serves(ScriptKind.instance, "instance_counter") && !runtime.serves(ScriptKind.creature, "instance_counter"));
    assert(!runtime.create(ScriptKind.creature, "nobody"), "no such script");

    // Compile-time checks: these would not build if registered.
    static assert(problemsOf!(Wrong, ScriptKind.instance).length > 0);
    static assert(problemsOf!(Unhandled, ScriptKind.creature).length > 0);
    static assert(problemsOf!(Counter, ScriptKind.creature).length == 0);

    auto host = new FakeCreature;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "npc_counter");
    assert(h && runtime.nameOf(h) == "npc_counter" && runtime.liveScripts == 1);
    assert(runtime.handles!EnteredCombat(h) && !runtime.handles!Died(h));

    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.raise(h, me, Damaged(EntityRef(7), 10, 60, 45));
    runtime.raise(h, me, Died()); // not handled: nothing
    assert(host.casts == [12_345] && runtime.busy(h));
    InstanceContext otherKind;
    runtime.tick(h, otherKind, 100_000); // a different kind cannot advance the creature's schedule
    foreach (_; 0 .. 25)
        runtime.tick(h, me, 100);
    // State, as the pool holds it: two pulses.
    ByteWriter w;
    runtime.save(h, w);
    Counter seen;
    import dmangos.script.state : loadScript;
    auto r = ByteReader(w.data);
    assert(loadScript(seen, r));
    assert(seen.fights == 1 && seen.hits == 1 && seen.pulses == 2 && seen.lastAfter == 45 && seen.enemy == EntityRef(7));

    // Another node (or a reload) builds the same state from the bytes.
    auto other = runtime.create(ScriptKind.creature, "npc_counter");
    auto r2 = ByteReader(w.data);
    assert(runtime.load(other, r2));
    runtime.tick(other, me, 1000);
    ByteWriter w2;
    runtime.save(other, w2);
    auto r3 = ByteReader(w2.data);
    assert(loadScript(seen, r3) && seen.pulses == 3, "its schedule went on where it was");

    // A dead entity's script goes; its handle (and any copy) is refused from then on.
    auto copy = h;
    runtime.destroy(h);
    assert(!h && runtime.liveScripts == 1);
    runtime.raise(copy, me, Damaged(EntityRef(7), 10, 40, 5));
    assert(host.casts == [12_345], "a stale handle does nothing");
    auto reused = runtime.create(ScriptKind.creature, "npc_counter");
    assert(reused.slot == copy.slot && reused.generation != copy.generation);
    runtime.raise(copy, me, EnteredCombat(EntityRef(9)));
    assert(!runtime.load(copy, r3), "nor loads");

    // Dungeon scripts: their own events and context.
    auto d = runtime.create(ScriptKind.instance, "instance_counter");
    assert(runtime.handles!CreatureDied(d) && !runtime.handles!ObjectLoaded(d));
}

/// Dispatch allocates nothing: a million events, ticks and checks.
unittest
{
    import core.memory : GC;

    alias self = dmangos.script.testscripts;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeCreature;
    auto h = runtime.create(ScriptKind.creature, "npc_counter");
    auto me = CreatureContext(host);
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    const before = GC.allocatedInCurrentThread;
    foreach (i; 0 .. 1_000_000)
    {
        runtime.raise(h, me, Damaged(EntityRef(7), 1, 90, 89));
        runtime.raise(h, me, Died());
        runtime.tick(h, me, 100);
        cast(void) runtime.busy(h);
    }
    assert(GC.allocatedInCurrentThread == before, "dispatch allocated");
}

/// An escorted creature: walks its path with its player, waits where the path says, fails if left.
@creature("npc_escorted")
struct Escorted
{
    Escort escort;
    uint[] reachedPoints;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point != uint.max)
            reachedPoints ~= point;
        if (point == 2)
            me.questEvent(escort.player, escort.quest);
    }
}

unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.script.state : loadScript;

    alias self = dmangos.script.testscripts;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeCreature;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "npc_escorted");
    Escorted state()
    {
        ByteWriter w;
        runtime.save(h, w);
        Escorted e;
        auto r = ByteReader(w.data);
        assert(loadScript(e, r));
        return e;
    }

    runtime.raise(h, me, QuestAccepted(EntityRef(7), 155));
    assert(host.moves.length == 1 && runtime.busy(h), "off to point 0");
    host.walking = false;
    runtime.raise(h, me, MovementDone(0));
    runtime.tick(h, me, 100); // no wait at 0: on to 1
    assert(host.moves.length == 2 && host.moves[1].x == 1);
    host.walking = false;
    runtime.raise(h, me, MovementDone(1));
    runtime.tick(h, me, 1500);
    assert(host.moves.length == 2, "waits two seconds at 1");
    runtime.tick(h, me, 600);
    assert(host.moves.length == 3);
    // Moved to another node without its movement: it is sent on again.
    host.walking = false;
    runtime.tick(h, me, 100);
    assert(host.moves.length == 4 && host.moves[3].x == 2);
    host.walking = false;
    runtime.raise(h, me, MovementDone(2));
    runtime.tick(h, me, 100);
    assert(state().reachedPoints == [0, 1, 2] && state().escort.finished && host.quests == ["event"]);
    assert(!runtime.busy(h), "done");

    // Another escort, left behind: it fails.
    auto h2 = runtime.create(ScriptKind.creature, "npc_escorted");
    runtime.raise(h2, me, QuestAccepted(EntityRef(7), 155));
    host.distance = 80;
    runtime.tick(h2, me, 100);
    assert(host.quests == ["event", "failed"] && !runtime.busy(h2));
}
