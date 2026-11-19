/**
 * Scripts found at compile time and run without allocating.
 *
 * A script is a struct carrying a UDA of its kind (`@creature("boss_mr_smite")`). `ScriptRuntime.of`
 * walks the modules it is given with `static foreach`, finds those structs, checks them (every `on`
 * handles an event of its kind or a step of one of its schedules; no name is served twice) and, for
 * each, generates a table of function pointers: one per event of its kind (null for those it does
 * not handle), its schedules' tick, and the persistence of its state.
 *
 * The state of every live script lives in a pool of its type: chunks of structs that never move
 * (a handler may make more scripted creatures while it runs). Entities hold a `ScriptHandle`; a
 * handle to a slot since reused is refused by its generation.
 */
module dmangos.script.registry;

import std.meta : AliasSeq, staticIndexOf;
import std.traits : getUDAs, hasUDA, isInstanceOf, Parameters, Unqual;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.script.api;
import dmangos.script.schedule : Schedule;
import dmangos.script.state : loadScript, saveScript;

// ---------------------------------------------------------------------------
// Kinds of scripts: their UDA, their context and their events
// ---------------------------------------------------------------------------

/// A creature script, for the `creature_template` rows with these `ScriptName`s.
struct creature
{
    string[] names;

    ///
    this(string[] names...) pure nothrow @safe
    {
        this.names = names.dup;
    }
}

/// A dungeon script, for the `instance_template` rows with these `ScriptName`s: one per copy.
struct instance
{
    string[] names;

    ///
    this(string[] names...) pure nothrow @safe
    {
        this.names = names.dup;
    }
}

/// A game object script, for the `gameobject_template` rows with these `ScriptName`s.
struct gameObject
{
    string[] names;

    ///
    this(string[] names...) pure nothrow @safe
    {
        this.names = names.dup;
    }
}

/// A spell script, for the `spell_scripts` rows with these `ScriptName`s.
struct spell
{
    string[] names;

    ///
    this(string[] names...) pure nothrow @safe
    {
        this.names = names.dup;
    }
}

/// An area trigger script, for the `scripted_areatrigger` rows with these `ScriptName`s.
struct areaTrigger
{
    string[] names;

    ///
    this(string[] names...) pure nothrow @safe
    {
        this.names = names.dup;
    }
}

/// A scripted event's script (`scripted_event_id`: an event a spell or a game object starts), for these names.
struct scriptedEvent
{
    string[] names;

    ///
    this(string[] names...) pure nothrow @safe
    {
        this.names = names.dup;
    }
}

/// What kind of script.
enum ScriptKind : ubyte
{
    creature,
    instance,
    gameObject,
    spell,
    areaTrigger,
    event,
}

/// The context and events of each kind.
template KindInfo(ScriptKind kind)
{
    static if (kind == ScriptKind.creature)
    {
        alias Context = CreatureContext;
        alias Events = AliasSeq!(Spawned, Reset, EnteredCombat, Damaged, KilledUnit, Died, Evaded, SpellHit, Signal,
            MovementDone, GossipHello, GossipSelect, QuestAccepted, QuestRewarded,
            // Eastern Kingdoms scripts:
            SummonedDied, SummonedArrived, UnitInSight, EmoteReceived);
        alias Attribute = .creature;
    }
    else static if (kind == ScriptKind.gameObject)
    {
        alias Context = GameObjectContext;
        alias Events = AliasSeq!(ObjectUsed, Signal);
        alias Attribute = .gameObject;
    }
    else static if (kind == ScriptKind.spell)
    {
        alias Context = SpellContext;
        alias Events = AliasSeq!(EffectHit, AuraApplied, AuraTicked);
        alias Attribute = .spell;
    }
    else static if (kind == ScriptKind.areaTrigger)
    {
        alias Context = AreaTriggerContext;
        alias Events = AliasSeq!(TriggerEntered);
        alias Attribute = .areaTrigger;
    }
    else static if (kind == ScriptKind.event)
    {
        alias Context = EventContext;
        alias Events = AliasSeq!(EventStarted);
        alias Attribute = .scriptedEvent;
    }
    else static if (kind == ScriptKind.instance)
    {
        alias Context = InstanceContext;
        alias Events = AliasSeq!(CreatureLoaded, ObjectLoaded, CreatureDied, Signal, CreatureEngaged, CreatureEvaded,
            EventHappened, /* Raid scripts: */ Asked, PlayerEntered, ObjectUsedHere);
        alias Attribute = .instance;
    }
}

/// The most events any kind has.
enum size_t maxEvents = () {
    size_t most;
    static foreach (k; __traits(allMembers, ScriptKind))
        if (KindInfo!(__traits(getMember, ScriptKind, k)).Events.length > most)
            most = KindInfo!(__traits(getMember, ScriptKind, k)).Events.length;
    return most;
}();

// ---------------------------------------------------------------------------
// Handles and pools
// ---------------------------------------------------------------------------

/// A live script: which script, which slot of its pool, and the slot's generation.
struct ScriptHandle
{
    ushort script; /// index in the runtime's table + 1; 0: none
    ushort generation;
    uint slot;

    /// Whether it names a script.
    bool opCast(T : bool)() const pure nothrow @nogc @safe
    {
        return script != 0;
    }
}

/// The states of one script type.
abstract class Pool
{
    /// A slot holding a fresh state; its generation is in `generation`.
    abstract uint acquire(out ushort generation);
    /// The slot is free again; handles to it are stale from now on.
    abstract void release(uint slot, ushort generation);
    /// The state in the slot; null for a stale handle.
    abstract void* at(uint slot, ushort generation);
    /// How many slots are in use.
    abstract @property size_t live() const;
}

/// See `Pool`.
final class TypedPool(S) : Pool
{
    private enum chunkSize = 64;
    private S[][] chunks;
    private ushort[] generations;
    private bool[] used;
    private uint[] free;
    private size_t live_;

    override uint acquire(out ushort generation)
    {
        uint slot;
        if (free.length)
        {
            slot = free[$ - 1];
            free = free[0 .. $ - 1];
            free.assumeSafeAppend();
        }
        else
        {
            slot = cast(uint) generations.length;
            if (slot % chunkSize == 0)
                chunks ~= new S[chunkSize];
            generations ~= 1;
            used ~= false;
        }
        chunks[slot / chunkSize][slot % chunkSize] = S.init;
        used[slot] = true;
        ++live_;
        generation = generations[slot];
        return slot;
    }

    override void release(uint slot, ushort generation)
    {
        if (slot >= used.length || !used[slot] || generations[slot] != generation)
            return;
        used[slot] = false;
        ++generations[slot];
        if (generations[slot] == 0)
            generations[slot] = 1;
        chunks[slot / chunkSize][slot % chunkSize] = S.init; // drops what it referenced
        free ~= slot;
        --live_;
    }

    override void* at(uint slot, ushort generation)
    {
        if (slot >= used.length || !used[slot] || generations[slot] != generation)
            return null;
        return &chunks[slot / chunkSize][slot % chunkSize];
    }

    override @property size_t live() const
    {
        return live_;
    }
}

// ---------------------------------------------------------------------------
// What is generated for each script
// ---------------------------------------------------------------------------

/// A script type as the runtime calls it.
struct ScriptType
{
    ScriptKind kind;
    string name;        /// the `ScriptName` it serves
    string typeName;    /// its struct, for messages
    Pool function() makePool;
    void*[maxEvents] handlers;                      /// `void function(void*, ref Context, const ref Event)`, by event index
    void function(void* state, void* context, int ms) tick; /// its schedules; null if it has none
    bool function(const(void)* state) busy;         /// whether a schedule has something pending
    void function(const(void)* state, ref ByteWriter w) save;
    bool function(void* state, ref ByteReader r) load;
}

/// The schedules among `S`'s fields.
private template scheduleFields(S)
{
    enum scheduleFields = () {
        size_t[] found;
        static foreach (i, T; typeof(S.tupleof))
            static if (isInstanceOf!(Schedule, T))
                found ~= i;
        return found;
    }();
}

/// The fields of `S` that tick with the script and are not schedules: components with
/// `tick(ref Context, int ms)` and `busy` (an `Escort`).
private template tickerFields(S, Ctx)
{
    enum tickerFields = () {
        size_t[] found;
        static foreach (i, T; typeof(S.tupleof))
            static if (!isInstanceOf!(Schedule, T) && is(T == struct)
                && __traits(compiles, (ref T t, ref Ctx c) { t.tick(c, 0); bool b = t.busy; }))
                found ~= i;
        return found;
    }();
}

/// The step enum of schedule type `T`.
private template StepOf(T)
{
    static if (is(T : Schedule!(E, n), E, size_t n))
        alias StepOf = E;
}

/// Compile-time checks of script `S` of `kind`: what is wrong with it, or null.
string problemsOf(S, ScriptKind kind)()
{
    alias Info = KindInfo!kind;
    string problems;
    static if (__traits(hasMember, S, "on"))
        static foreach (handler; __traits(getOverloads, S, "on"))
        {{
            alias P = Parameters!handler;
            bool known;
            static if (P.length == 2 && is(P[0] == Info.Context))
            {
                static if (staticIndexOf!(Unqual!(P[1]), Info.Events) >= 0)
                    known = true;
                static foreach (i; scheduleFields!S)
                    static if (is(Unqual!(P[1]) == StepOf!(typeof(S.tupleof[i]))))
                        known = true;
            }
            if (!known)
                problems ~= S.stringof ~ ".on" ~ P.stringof ~ ": not an event of a " ~ kind.stringof
                    ~ " script (on(ref " ~ Info.Context.stringof ~ ", const ref Event) or a step of one of its schedules)\n";
        }}
    static foreach (i; scheduleFields!S)
        static if (!__traits(compiles, (ref S s, ref Info.Context c) => s.on(c, StepOf!(typeof(S.tupleof[i])).init)))
            problems ~= S.stringof ~ "." ~ __traits(identifier, S.tupleof[i]) ~ ": no on(ref " ~ Info.Context.stringof
                ~ ", " ~ StepOf!(typeof(S.tupleof[i])).stringof ~ ") for its steps\n";
    return problems;
}

/// The runtime's description of script `S` of `kind`, serving `name`.
ScriptType describe(S, ScriptKind kind)(string name)
{
    alias Info = KindInfo!kind;
    alias Ctx = Info.Context;
    ScriptType t;
    t.kind = kind;
    t.name = name;
    t.typeName = S.stringof;
    t.makePool = () => cast(Pool) new TypedPool!S;
    static foreach (i, E; Info.Events)
        static if (__traits(compiles, (ref S s, ref Ctx c, const ref E e) => s.on(c, e)))
            t.handlers[i] = cast(void*) &dispatchEvent!(S, Ctx, E);
    static if (scheduleFields!S.length || tickerFields!(S, Ctx).length)
    {
        t.tick = &tickSchedules!(S, Ctx);
        t.busy = (const(void)* p) {
            const s = cast(const(S)*) p;
            static foreach (i; scheduleFields!S)
                if (s.tupleof[i].busy)
                    return true;
            static foreach (i; tickerFields!(S, Ctx))
                if (s.tupleof[i].busy)
                    return true;
            return false;
        };
    }
    t.save = (const(void)* p, ref ByteWriter w) => saveScript(*cast(const(S)*) p, w);
    t.load = (void* p, ref ByteReader r) => loadScript(*cast(S*) p, r);
    return t;
}

private void dispatchEvent(S, Ctx, E)(void* state, ref Ctx context, const ref E event)
{
    (cast(S*) state).on(context, event);
}

private void tickSchedules(S, Ctx)(void* state, void* context, int ms)
{
    auto s = cast(S*) state;
    auto c = cast(Ctx*) context;
    static foreach (i; scheduleFields!S)
        s.tupleof[i].advance(ms, (StepOf!(typeof(S.tupleof[i])) step) { s.on(*c, step); });
    static foreach (i; tickerFields!(S, Ctx))
        s.tupleof[i].tick(*c, ms);
}

// ---------------------------------------------------------------------------
// The runtime
// ---------------------------------------------------------------------------

/// Every `(kind, name)` the scripts of `Modules` serve, checked: a name served twice fails the build.
private string[] servedNames(Modules...)()
{
    string[] all;
    static foreach (M; Modules)
        static foreach (member; __traits(allMembers, M))
            static if (is(__traits(getMember, M, member) == struct))
                static foreach (k; __traits(allMembers, ScriptKind))
                    static foreach (uda; getUDAs!(__traits(getMember, M, member), KindInfo!(__traits(getMember, ScriptKind, k)).Attribute))
                        foreach (name; uda.names)
                            all ~= k ~ ":" ~ name;
    return all;
}

private string duplicateOf(string[] names)
{
    foreach (i, a; names)
        foreach (b; names[i + 1 .. $])
            if (a == b)
                return a;
    return null;
}

/// The scripts of a server, their pools, and dispatch.
final class ScriptRuntime
{
    private ScriptType[] types;
    private Pool[] pools;
    private ushort[string][ScriptKind.max + 1] byName;

    /// The scripts of `Modules`, found and checked at compile time.
    static ScriptRuntime of(Modules...)()
    {
        enum duplicate = duplicateOf(servedNames!Modules());
        static assert(duplicate is null, "two scripts serve " ~ duplicate);
        auto runtime = new ScriptRuntime;
        static foreach (M; Modules)
            static foreach (member; __traits(allMembers, M))
                static if (is(__traits(getMember, M, member) == struct))
                    static foreach (k; __traits(allMembers, ScriptKind))
                    {{
                        enum kind = __traits(getMember, ScriptKind, k);
                        alias S = __traits(getMember, M, member);
                        static if (hasUDA!(S, KindInfo!kind.Attribute))
                        {
                            enum problems = problemsOf!(S, kind)();
                            static assert(problems.length == 0, problems);
                            static foreach (uda; getUDAs!(S, KindInfo!kind.Attribute))
                                foreach (name; uda.names)
                                    runtime.add(describe!(S, kind)(name));
                        }
                    }}
        return runtime;
    }

    /// Adds a script (`of` does; tests may too).
    void add(ScriptType type)
    {
        types ~= type;
        pools ~= type.makePool();
        byName[type.kind][type.name] = cast(ushort) types.length;
    }

    /// The names served for `kind`.
    const(string)[] names(ScriptKind kind) const
    {
        return byName[kind].keys;
    }

    /// Whether a script serves `name` for `kind`.
    bool serves(ScriptKind kind, string name) const
    {
        return (name in byName[kind]) !is null;
    }

    /// A fresh state of the script serving `name` for `kind`; no handle if none does.
    ScriptHandle create(ScriptKind kind, string name)
    {
        if (!name.length)
            return ScriptHandle.init;
        const index = byName[kind].get(name, 0);
        if (index == 0)
            return ScriptHandle.init;
        ScriptHandle h;
        h.script = index;
        h.slot = pools[index - 1].acquire(h.generation);
        return h;
    }

    /// The script's state goes; the handle (and copies of it) are stale from now on.
    void destroy(ref ScriptHandle h)
    {
        if (h)
            pools[h.script - 1].release(h.slot, h.generation);
        h = ScriptHandle.init;
    }

    /// The `ScriptName` of a handle's script; null if none.
    string nameOf(ScriptHandle h) const
    {
        return h ? types[h.script - 1].name : null;
    }

    /// Whether the script handles `E` (a cheap test before building the event).
    bool handles(E)(ScriptHandle h) const
    {
        if (!h)
            return false;
        const t = &types[h.script - 1];
        static foreach (k; __traits(allMembers, ScriptKind))
        {{
            enum index = staticIndexOf!(E, KindInfo!(__traits(getMember, ScriptKind, k)).Events);
            static if (index >= 0)
                if (t.kind == __traits(getMember, ScriptKind, k))
                    return t.handlers[index] !is null;
        }}
        return false;
    }

    /// Tells the script of `event`. Nothing if it does not handle it or the handle is stale.
    void raise(Ctx, E)(ScriptHandle h, ref Ctx context, const auto ref E event)
    {
        if (!h)
            return;
        const t = &types[h.script - 1];
        static foreach (k; __traits(allMembers, ScriptKind))
        {{
            enum kind = __traits(getMember, ScriptKind, k);
            static if (is(KindInfo!kind.Context == Ctx))
            {
                enum index = staticIndexOf!(E, KindInfo!kind.Events);
                static assert(index >= 0, E.stringof ~ " is not an event of a " ~ kind.stringof ~ " script");
                if (t.kind != kind || t.handlers[index] is null)
                    return;
                auto state = pools[h.script - 1].at(h.slot, h.generation);
                if (state is null)
                    return;
                (cast(void function(void*, ref Ctx, const ref E)) t.handlers[index])(state, context, event);
            }
        }}
    }

    /// `ms` of the entity's time pass for the script's schedules.
    void tick(Ctx)(ScriptHandle h, ref Ctx context, int ms)
    {
        if (!h)
            return;
        const t = &types[h.script - 1];
        if (t.tick is null)
            return;
        if (auto state = pools[h.script - 1].at(h.slot, h.generation))
            t.tick(state, &context, ms);
    }

    /// Whether the script has steps pending (its entity must tick).
    bool busy(ScriptHandle h)
    {
        if (!h)
            return false;
        const t = &types[h.script - 1];
        auto state = pools[h.script - 1].at(h.slot, h.generation);
        return state !is null && t.busy !is null && t.busy(state);
    }

    /// Writes the script's state (nothing for no script).
    void save(ScriptHandle h, ref ByteWriter w)
    {
        if (auto state = h ? pools[h.script - 1].at(h.slot, h.generation) : null)
            types[h.script - 1].save(state, w);
    }

    /// Reads what `save` wrote into the script; false if it does not fit (its layout changed).
    bool load(ScriptHandle h, ref ByteReader r)
    {
        auto state = h ? pools[h.script - 1].at(h.slot, h.generation) : null;
        return state !is null && types[h.script - 1].load(state, r);
    }

    /// Scripts alive, of every type.
    @property size_t liveScripts() const
    {
        size_t n;
        foreach (p; pools)
            n += p.live;
        return n;
    }
}
