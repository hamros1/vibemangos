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
    bool hostInCombat() { return true; }
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
