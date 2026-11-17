/**
 * What scripts see of the world: entity handles, the events each kind of script is told of, and
 * the context through which it acts.
 *
 * A script never holds an object: it holds `EntityRef`s (guids, stable on every node and across
 * moves between nodes) and asks its context to act on them. The context resolves a guid at the
 * moment of the call, on this node, and answers with an `ActionResult` when the entity is not here
 * or the action is not allowed; every action goes through the same rules as a player's. The core
 * implements the *host* interfaces below; the framework never imports the core.
 */
module dmangos.script.api;

// ---------------------------------------------------------------------------
// Handles and values
// ---------------------------------------------------------------------------

/// An entity, by guid. Holding one is always safe: it is resolved only when used.
struct EntityRef
{
    ulong guid;

    /// Whether it names anything.
    bool opCast(T : bool)() const pure nothrow @nogc @safe
    {
        return guid != 0;
    }

    /// What kind of entity it is (the guid's high part).
    @property bool isPlayer() const pure nothrow @nogc @safe
    {
        return guid != 0 && guid >> 48 == 0;
    }

    /// ditto
    @property bool isCreature() const pure nothrow @nogc @safe
    {
        return guid >> 48 == 0xF130;
    }

    /// ditto
    @property bool isGameObject() const pure nothrow @nogc @safe
    {
        return guid >> 48 == 0xF110;
    }

    /// The entry (template) of a creature or game object; 0 for a player.
    @property uint entry() const pure nothrow @nogc @safe
    {
        return isPlayer ? 0 : cast(uint)(guid >> 24) & 0xFF_FFFF;
    }
}

/// A place on the entity's map.
struct Location
{
    float x = 0, y = 0, z = 0, orientation = 0;
}

/// How an action went.
enum ActionResult : ubyte
{
    ok,
    notHere,    /// the entity is not on this node (not loaded, gone, or another node's)
    notAllowed, /// the rules forbid it (out of range, dead, not hostile, a spell it cannot cast now)
    failed,     /// it could not be done (no such spell, no room)
}

/// `UnitStandStateType`, as far as scripts use it.
enum StandState : ubyte
{
    stand = 0,
    sit = 1,
    sleep = 3,
    dead = 7,
    kneel = 8,
}

// ---------------------------------------------------------------------------
// Creature scripts (`@creature`, bound by `creature_template.ScriptName`)
// ---------------------------------------------------------------------------

/// It has just come into the world (spawned, respawned), before anything else happens to it.
struct Spawned
{
}

/// It is back home after a fight it gave up (`Reset`): put its state back as it was.
struct Reset
{
}

/// It started fighting `enemy` (`Aggro`, `JustEngagedWith`).
struct EnteredCombat
{
    EntityRef enemy;
}

/// It was hurt: `amount`, its health going from `before` to `after` percent.
struct Damaged
{
    EntityRef attacker;
    uint amount;
    ubyte before, after;

    /// Whether this blow took it to `percent` or below (from above it).
    bool crossed(ubyte percent) const pure nothrow @nogc @safe
    {
        return before > percent && after <= percent;
    }
}

/// It killed `victim` (`KilledUnit`).
struct KilledUnit
{
    EntityRef victim;
}

/// It died, its last enemy `killer` (`JustDied`).
struct Died
{
    EntityRef killer;
}

/// It gave up the fight and goes home (`EnterEvadeMode`).
struct Evaded
{
}

/// `caster`'s spell `spell` hit it (`SpellHit`).
struct SpellHit
{
    EntityRef caster;
    uint spell;
}

/// A message from another script (`from`: a creature, or nothing for its dungeon's script).
struct Signal
{
    EntityRef from;
    uint id;
    int value;
}

/// The core's side of a creature script's context (`CreatureAI` implements it).
interface CreatureHost
{
    EntityRef hostSelf();
    EntityRef hostVictim();
    uint hostHealthPercent();
    bool hostInCombat();
    Location hostLocation();
    uint hostHealthPercentOf(EntityRef who);
    ActionResult hostCast(uint spell, EntityRef target, bool triggered);
    ActionResult hostSay(int textEntry, EntityRef target);
    void hostEquip(uint mainHand, uint offHand, uint ranged);
    void hostRestoreEquipment();
    void hostStandState(StandState state);
    void hostCombatMovement(bool on);
    void hostMelee(bool on);
    EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack);
    void hostDespawn(uint delayMs);
    ActionResult hostSignal(EntityRef to, uint id, int value);
    void hostSignalDungeon(uint id, int value);
    void hostLog(string text);
}

/**
 * A creature script's handle on its creature and the world, for the length of one handler. It
 * cannot be copied or kept: what persists is the script's own state.
 */
struct CreatureContext
{
    private CreatureHost host;

    @disable this(this);

    /// The core makes one around its creature.
    this(CreatureHost host) pure nothrow @nogc @safe
    {
        this.host = host;
    }

    /// The creature itself.
    @property EntityRef self() { return host.hostSelf(); }

    /// Whom it fights; nothing when it does not.
    @property EntityRef victim() { return host.hostVictim(); }

    /// Its health in percent.
    @property uint healthPercent() { return host.hostHealthPercent(); }

    /// Whether it is fighting.
    @property bool inCombat() { return host.hostInCombat(); }

    /// Where it is.
    @property Location location() { return host.hostLocation(); }

    /// Another unit's health in percent; uint.max if it is not here.
    uint healthPercentOf(EntityRef who) { return host.hostHealthPercentOf(who); }

    /// Casts `spell` at `target` (by default its victim), as its spells are cast: range, line of
    /// sight, power and the spell's own rules apply. `triggered`: no cast time, no cost.
    ActionResult castSpell(uint spell, EntityRef target = EntityRef.init, bool triggered = false)
    {
        return host.hostCast(spell, target ? target : host.hostVictim(), triggered);
    }

    /// Casts `spell` at itself.
    ActionResult castSelf(uint spell, bool triggered = false)
    {
        return host.hostCast(spell, host.hostSelf(), triggered);
    }

    /// Says (yells, emotes: as the row says) the `script_texts` row `entry` (negative), with its sound and emote.
    ActionResult say(int entry, EntityRef target = EntityRef.init) { return host.hostSay(entry, target); }

    /// Holds these items (item entries; 0: nothing in that hand).
    void equip(uint mainHand, uint offHand = 0, uint ranged = 0) { host.hostEquip(mainHand, offHand, ranged); }

    /// Holds what its template gives it again.
    void restoreEquipment() { host.hostRestoreEquipment(); }

    /// Stands, sits, kneels.
    void standState(StandState state) { host.hostStandState(state); }

    /// Whether it follows its victim in a fight.
    void combatMovement(bool on) { host.hostCombatMovement(on); }

    /// Whether it swings at its victim.
    void melee(bool on) { host.hostMelee(on); }

    /// A creature of `entry` at `at` (its own place if zero), gone after `despawnMs` (0: when it dies),
    /// attacking `attack`; nothing if it could not be made.
    EntityRef summon(uint entry, Location at = Location.init, uint despawnMs = 0, EntityRef attack = EntityRef.init)
    {
        return host.hostSummon(entry, at, despawnMs, attack);
    }

    /// Goes away (to come back after its respawn time) in `delayMs`.
    void despawn(uint delayMs = 0) { host.hostDespawn(delayMs); }

    /// A `Signal` for another creature's script.
    ActionResult signal(EntityRef to, uint id, int value = 0) { return host.hostSignal(to, id, value); }

    /// A `Signal` for its dungeon's script (nothing outside a dungeon).
    void signalDungeon(uint id, int value = 0) { host.hostSignalDungeon(id, value); }

    /// A line in the server's log, naming the creature.
    void log(string text) { host.hostLog(text); }
}

// ---------------------------------------------------------------------------
// Dungeon scripts (`@instance`, bound by `instance_template.ScriptName`), one per copy
// ---------------------------------------------------------------------------

/// A creature of the copy came into the world (its cell loaded, or it respawned).
struct CreatureLoaded
{
    EntityRef creature;
}

/// A game object of the copy came into the world.
struct ObjectLoaded
{
    EntityRef object;
}

/// A creature of the copy died.
struct CreatureDied
{
    EntityRef creature;
    EntityRef killer;
}

/// The core's side of a dungeon script's context.
interface InstanceHost
{
    uint hostMapId();
    uint hostInstanceId();
    ActionResult hostDoor(EntityRef door, bool open);
    ActionResult hostSignal(EntityRef to, uint id, int value);
    uint hostPlayerCount();
    void hostLog(string text);
}

/// A dungeon script's handle on its copy, for the length of one handler.
struct InstanceContext
{
    private InstanceHost host;

    @disable this(this);

    /// The core makes one around a copy.
    this(InstanceHost host) pure nothrow @nogc @safe
    {
        this.host = host;
    }

    /// The dungeon's map and this copy's id.
    @property uint mapId() { return host.hostMapId(); }
    /// ditto
    @property uint instanceId() { return host.hostInstanceId(); }

    /// Opens or closes a door (it stays so).
    ActionResult door(EntityRef door, bool open) { return host.hostDoor(door, open); }

    /// A `Signal` for a creature's script in the copy.
    ActionResult signal(EntityRef to, uint id, int value = 0) { return host.hostSignal(to, id, value); }

    /// The players in the copy.
    @property uint playerCount() { return host.hostPlayerCount(); }

    /// A line in the server's log, naming the copy.
    void log(string text) { host.hostLog(text); }
}

unittest
{
    const creature = EntityRef(0xF130_0002_8600_0123); // entry 646 (0x286), spawn 0x123
    assert(creature.isCreature && !creature.isPlayer && creature.entry == 646);
    assert(EntityRef(7).isPlayer && EntityRef(7).entry == 0 && !EntityRef.init);
    assert(Damaged(EntityRef.init, 10, 70, 60).crossed(66) && !Damaged(EntityRef.init, 10, 66, 60).crossed(66));
}
