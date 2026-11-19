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

/// Where a player stands with a quest.
enum QuestProgress : ubyte
{
    none,       /// not taken (or abandoned)
    incomplete, /// under way
    complete,   /// its objectives done, not yet handed in
    failed,
    rewarded,   /// handed in
}

/// `GossipOptionIcon`
enum GossipIcon : ubyte
{
    chat = 0,
    vendor = 1,
    taxi = 2,
    trainer = 3,
    interact = 4,
}

/// An option of a gossip menu a script builds.
struct MenuOption
{
    GossipIcon icon;
    string text;
    uint action; /// what `GossipSelect.action` says when it is chosen
}

/// A gossip menu a script builds: up to 16 options, kept on the stack.
struct GossipMenu
{
    private MenuOption[16] options_;
    private ubyte count;

    /// Adds an option (beyond 16: ignored).
    ref GossipMenu add(GossipIcon icon, string text, uint action) return
    {
        if (count < options_.length)
            options_[count++] = MenuOption(icon, text, action);
        return this;
    }

    /// The options added.
    const(MenuOption)[] options() const return
    {
        return options_[0 .. count];
    }
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

// Eastern Kingdoms scripts:

/// How a creature reacts to others (`ReactStates`).
enum Reaction : ubyte
{
    passive,    /// never fights
    defensive,  /// fights back
    aggressive, /// also attacks on sight
}

/// `SheathState`: its weapons put away, or drawn.
enum Sheath : ubyte
{
    unarmed = 0,
    melee = 1,
    ranged = 2,
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

/// It arrived at the point of its `moveTo` numbered `point`.
struct MovementDone
{
    uint point;
}

/// A player spoke to it (`GossipHello`). `CreatureContext.consume` keeps its usual menu from showing.
struct GossipHello
{
    EntityRef player;
}

/// A player chose option `option` of gossip menu `menu` (`GossipSelect`); `consume` keeps the usual action.
struct GossipSelect
{
    EntityRef player;
    uint menu;   /// the `gossip_menu` shown; 0 for a menu the script built
    uint option; /// the option's place in the menu
    uint action; /// a script's menu: the option's action
}

/// A player took quest `quest` from it.
struct QuestAccepted
{
    EntityRef player;
    uint quest;
}

/// A player was rewarded for quest `quest` by it.
struct QuestRewarded
{
    EntityRef player;
    uint quest;
}

/// A point of a creature's escort path (`script_waypoint`).
struct Waypoint
{
    Location at;
    uint waitMs; /// how long it stays there
    uint scriptId; /// Eastern Kingdoms scripts: its `dbscripts_on_creature_movement` script (0: none)
}

// Eastern Kingdoms scripts:

/// A creature it summoned died (`SummonedCreatureJustDied`), or went away alive, its time up
/// (`SummonedCreatureDespawn`; `gone`).
struct SummonedDied
{
    EntityRef summoned;
    EntityRef killer;
    bool gone; /// it did not die: its summoned time was up
}

/// A creature it summoned and sent somewhere (`CreatureContext.moveCreature`) arrived at `point`
/// (`SummonedMovementInform`).
struct SummonedArrived
{
    EntityRef summoned;
    uint point;
}

/// A player (or a pet) came into its sight (`MoveInLineOfSight`), before it decides whether to attack.
struct UnitInSight
{
    EntityRef unit;
}

/// A player made a text emote (`TextEmotes`: 34 chicken, 21 cheer, 101 wave, ...) at it (`ReceiveEmote`).
struct EmoteReceived
{
    EntityRef player;
    uint textEmote;
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
    void hostMoveTo(Location at, uint point, bool run);
    bool hostMoving();
    bool hostWaypoint(size_t index, out Waypoint point);
    size_t hostWaypointCount();
    float hostDistanceTo(EntityRef who);
    bool hostAlive(EntityRef who);
    void hostQuestEvent(EntityRef player, uint quest);
    void hostFailQuest(EntityRef player, uint quest);
    void hostNpcFlags(uint flags);
    void hostRestoreNpcFlags();
    void hostGossipMenu(EntityRef player, uint menu);
    void hostCloseGossip(EntityRef player);
    uint hostRandom(uint below);
    QuestProgress hostQuestStatus(EntityRef player, uint quest);
    EntityRef hostRandomTarget();
    ActionResult hostSayBroadcast(EntityRef speaker, uint text, EntityRef target);
    void hostEmote(uint emote);
    EntityRef hostCreatureNearby(uint entry, float range);
    ActionResult hostDespawnOther(EntityRef creature, uint delayMs);
    void hostSendGossip(EntityRef player, uint textId, const(MenuOption)[] options, bool withQuests);

    // Eastern Kingdoms scripts:
    void hostSetFaction(uint faction);
    void hostUnitFlags(uint flags, bool set);
    void hostReactState(Reaction state);
    void hostDeathPrevention(bool on);
    void hostEvade();
    ActionResult hostAttackBy(EntityRef attacker, EntityRef target);
    ActionResult hostMoveOther(EntityRef creature, Location at, uint point, bool run);
    void hostFace(EntityRef target);
    void hostSheath(Sheath state);
    void hostMount(uint display);
    void hostDie();
    bool hostChangeEntry(uint entry);
    EntityRef hostObjectNearby(uint entry, float range);
    ActionResult hostUseObject(EntityRef object);
    ActionResult hostRemoveAura(EntityRef who, uint spell);
    bool hostHasAura(EntityRef who, uint spell);
    ActionResult hostSayOther(EntityRef speaker, int entry, EntityRef target);
    void hostMovementScript(uint id);
    void hostRelay(int id, EntityRef target);
    void hostKillCredit(EntityRef player, uint entry);
    // Dungeon scripts:
    void hostFollow(EntityRef leader, float distance, float angle);
    EntityRef hostPlayerNearby(float range);
    bool hostLocate(EntityRef who, out Location at);
}

/// `UnitFlags`, as dungeon scripts set and clear them (`CreatureContext.unitFlags`).
enum UnitFlag : uint
{
    nonAttackable = 0x0000_0002,  /// `UNIT_FLAG_SPAWNING`: nobody can attack it
    immuneToPlayer = 0x0000_0100, /// players cannot attack it, nor it them
    immuneToNpc = 0x0000_0200,    /// nor creatures
    notSelectable = 0x0200_0000,  /// it cannot be clicked or targeted
}

/**
 * A creature script's handle on its creature and the world, for the length of one handler. It
 * cannot be copied or kept: what persists is the script's own state.
 */
struct CreatureContext
{
    private CreatureHost host;
    private bool consumed_;

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

    /// Walks (runs) to `at` in a straight line; `MovementDone(point)` follows on arrival. A fight
    /// interrupts it; once home from the fight it goes on there.
    void moveTo(Location at, uint point, bool run = false) { host.hostMoveTo(at, point, run); }

    /// Whether it is on its way somewhere (a `moveTo`, or a path of its own).
    @property bool moving() { return host.hostMoving(); }

    /// Point `index` of its escort path (`script_waypoint`); false past the end.
    bool waypoint(size_t index, out Waypoint point) { return host.hostWaypoint(index, point); }

    /// How many points its escort path has.
    @property size_t waypointCount() { return host.hostWaypointCount(); }

    /// Yards to another entity on its map (seen here, if another node simulates it); infinity if not.
    float distanceTo(EntityRef who) { return host.hostDistanceTo(who); }

    /// Whether a unit is alive (one not here counts as alive: nothing is known of it).
    bool alive(EntityRef who) { return host.hostAlive(who); }

    /// `AreaExploredOrEventHappens`: the event quest `quest` waits for happened for `player`.
    void questEvent(EntityRef player, uint quest) { host.hostQuestEvent(player, quest); }

    /// `FailQuest`: `player`'s quest under way fails.
    void failQuest(EntityRef player, uint quest) { host.hostFailQuest(player, quest); }

    /// Its NPC flags (gossip, quest giver, ...), until `restoreNpcFlags`.
    void npcFlags(uint flags) { host.hostNpcFlags(flags); }

    /// Its template's NPC flags again.
    void restoreNpcFlags() { host.hostRestoreNpcFlags(); }

    /// Shows `player` the `gossip_menu` `menu` from it.
    void gossipMenu(EntityRef player, uint menu) { host.hostGossipMenu(player, menu); }

    /// Closes `player`'s gossip window.
    void closeGossip(EntityRef player) { host.hostCloseGossip(player); }

    /// Shows `player` a menu the script built, under `npc_text` `textId` (0: its usual greeting; with its quests, by default);
    /// the option chosen comes back as `GossipSelect` with its action.
    void sendGossip(EntityRef player, uint textId, const ref GossipMenu menu, bool withQuests = true)
    {
        host.hostSendGossip(player, textId, menu.options, withQuests);
    }

    /// Where `player` stands with `quest`.
    QuestProgress questStatus(EntityRef player, uint quest) { return host.hostQuestStatus(player, quest); }

    /// One of those it fights (its threat list), at random; nothing if it fights nobody.
    EntityRef randomTarget() { return host.hostRandomTarget(); }

    /// Says (yells, emotes: as the row says) the `broadcast_text` row `text`.
    ActionResult sayText(uint text, EntityRef target = EntityRef.init)
    {
        return host.hostSayBroadcast(host.hostSelf(), text, target);
    }

    /// Another creature here says `broadcast_text` row `text` (a scene with two speakers).
    ActionResult sayAs(EntityRef speaker, uint text, EntityRef target = EntityRef.init)
    {
        return host.hostSayBroadcast(speaker, text, target);
    }

    /// Plays emote `emote` (`Emotes`: 1 talk, 25 point, ...).
    void emote(uint emote) { host.hostEmote(emote); }

    /// A living creature of `entry` within `range` yards of it; nothing if none.
    EntityRef creatureNearby(uint entry, float range) { return host.hostCreatureNearby(entry, range); }

    /// Another creature here goes away (to come back after its respawn time) in `delayMs`.
    ActionResult despawn(EntityRef creature, uint delayMs = 0) { return host.hostDespawnOther(creature, delayMs); }

    /// A random number below `below` (from the map's generator).
    uint random(uint below) { return host.hostRandom(below); }

    /// For `GossipHello` and `GossipSelect`: the script answered; the usual menu or action does not follow.
    void consume() { consumed_ = true; }

    /// Whether a handler called `consume`.
    @property bool consumed() const { return consumed_; }

    // Eastern Kingdoms scripts:

    /// Its faction (`FactionTemplate.dbc`), until it respawns; 0: its template's again.
    void setFaction(uint faction) { host.hostSetFaction(faction); }

    /// Sets (or clears) unit flags (`UnitFlags`: 0x100 immune to players, 0x200 immune to creatures,
    /// 0x2000000 not interactible).
    void unitFlags(uint flags, bool set = true) { host.hostUnitFlags(flags, set); }

    /// Whether it attacks on sight, only fights back, or never fights.
    void reactState(Reaction state) { host.hostReactState(state); }

    /// While on, a blow that would kill it leaves it at 1 health (`Damaged` still says it).
    void deathPrevention(bool on) { host.hostDeathPrevention(on); }

    /// Gives up its fight and goes back where it started it (`Evaded`, then `Reset` there).
    void evade() { host.hostEvade(); }

    /// It (or another creature here, `attacker`) attacks `target`.
    ActionResult attack(EntityRef target) { return host.hostAttackBy(host.hostSelf(), target); }

    /// ditto
    ActionResult attack(EntityRef attacker, EntityRef target) { return host.hostAttackBy(attacker, target); }

    /// Another creature here walks (runs) to `at`; if it is one this creature summoned, its arrival comes
    /// back to this script as `SummonedArrived(point)`.
    ActionResult moveCreature(EntityRef creature, Location at, uint point, bool run = false)
    {
        return host.hostMoveOther(creature, at, point, run);
    }

    /// Turns to face `target`.
    void face(EntityRef target) { host.hostFace(target); }

    /// Draws its weapons (or puts them away).
    void sheath(Sheath state) { host.hostSheath(state); }

    /// Rides model `display`; 0: off its mount.
    void mount(uint display) { host.hostMount(display); }

    /// Dies, nobody's kill.
    void die() { host.hostDie(); }

    /// Becomes a creature of `entry` (its name, model, faction, level); false if there is no such entry.
    bool changeEntry(uint entry) { return host.hostChangeEntry(entry); }

    /// A game object of `entry` within `range` yards of it; nothing if none.
    EntityRef objectNearby(uint entry, float range) { return host.hostObjectNearby(entry, range); }

    /// Uses a door, button or cage near it: open for the object's own time, then closed again.
    ActionResult useObject(EntityRef object) { return host.hostUseObject(object); }

    /// `spell`'s aura goes from `who` (itself, another creature here, a player).
    ActionResult removeAura(EntityRef who, uint spell) { return host.hostRemoveAura(who, spell); }

    /// Whether `who` (itself or another creature here) has `spell`'s aura.
    bool hasAura(EntityRef who, uint spell) { return host.hostHasAura(who, spell); }

    /// Runs `dbscripts_on_creature_movement` script `id` on it (as a waypoint's script runs).
    void movementScript(uint id) { host.hostMovementScript(id); }

    /// Starts `dbscripts_on_relay` script `id` (negative: one of relay group -`id`) on it, with `target`.
    void relay(int id, EntityRef target = EntityRef.init) { host.hostRelay(id, target); }

    /// `KilledMonsterCredit` (or `TalkedToCreature`) of `entry` for `player`.
    void killCredit(EntityRef player, uint entry) { host.hostKillCredit(player, entry); }

    /// Another creature here says the `script_texts` row `entry` (negative), with its sound and emote.
    ActionResult sayOther(EntityRef speaker, int entry, EntityRef target = EntityRef.init)
    {
        return host.hostSayOther(speaker, entry, target);
    }

    // Dungeon scripts:

    /// Follows `leader` (a player, a creature), `distance` yards from it at `angle` (radians) from
    /// its facing, until it is told to go elsewhere; after a fight it follows again.
    void follow(EntityRef leader, float distance = 2, float angle = 3.14159f)
    {
        host.hostFollow(leader, distance, angle);
    }

    /// The nearest living player within `range` yards that may be attacked; nothing if none.
    EntityRef playerNearby(float range) { return host.hostPlayerNearby(range); }

    /// Where another entity on its map is; false (and `at` untouched) if it is not seen here.
    bool locate(EntityRef who, out Location at) { return host.hostLocate(who, at); }
}

// ---------------------------------------------------------------------------
// Game object scripts (`@gameObject`, bound by `gameobject_template.ScriptName`)
// ---------------------------------------------------------------------------

/// A player used it (`GOUse`). `GameObjectContext.consume` keeps the usual use from following.
struct ObjectUsed
{
    EntityRef player;
}

/// The core's side of a game object script's context.
interface GameObjectHost
{
    EntityRef hostSelf();
    void hostDoor(bool open);
    void hostSignalDungeon(uint id, int value);
    void hostLog(string text);

    // Eastern Kingdoms scripts:
    QuestProgress hostQuestStatus(EntityRef player, uint quest);
    void hostQuestEvent(EntityRef player, uint quest);
    EntityRef hostObjectNearby(uint entry, float range);
    ActionResult hostObjectOpen(EntityRef object, bool open);
    ActionResult hostObjectFlags(EntityRef object, uint flags, bool set);
    EntityRef hostCreatureNearby(uint entry, float range);
    EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack);
    ActionResult hostSayAs(EntityRef speaker, uint text, EntityRef target);
    void hostKillCredit(EntityRef player, uint entry);
}

/// A game object script's handle on its object, for the length of one handler.
struct GameObjectContext
{
    private GameObjectHost host;
    private bool consumed_;

    @disable this(this);

    /// The core makes one around its object.
    this(GameObjectHost host) pure nothrow @nogc @safe
    {
        this.host = host;
    }

    /// The object itself.
    @property EntityRef self() { return host.hostSelf(); }

    /// Opens or closes it (a door, a goober), for good.
    void open(bool open) { host.hostDoor(open); }

    /// A `Signal` for its dungeon's script (nothing outside a dungeon).
    void signalDungeon(uint id, int value = 0) { host.hostSignalDungeon(id, value); }

    /// A line in the server's log, naming the object.
    void log(string text) { host.hostLog(text); }

    /// The script handled the use; the usual use does not follow.
    void consume() { consumed_ = true; }

    /// Whether a handler called `consume`.
    @property bool consumed() const { return consumed_; }

    // Eastern Kingdoms scripts:

    /// Where `player` stands with `quest`.
    QuestProgress questStatus(EntityRef player, uint quest) { return host.hostQuestStatus(player, quest); }

    /// `AreaExploredOrEventHappens` for `player`.
    void questEvent(EntityRef player, uint quest) { host.hostQuestEvent(player, quest); }

    /// Another game object of `entry` within `range` yards of it; nothing if none.
    EntityRef objectNearby(uint entry, float range) { return host.hostObjectNearby(entry, range); }

    /// Opens or closes another game object here (itself too), for good.
    ActionResult open(EntityRef object, bool open) { return host.hostObjectOpen(object, open); }

    /// Sets (or clears) a game object's flags (`GameObjectFlags`: 0x1 in use, 0x2 locked, 0x4 needs a
    /// condition to be used, 0x10 not selectable).
    ActionResult objectFlags(EntityRef object, uint flags, bool set) { return host.hostObjectFlags(object, flags, set); }

    /// A living creature of `entry` within `range` yards of it; nothing if none.
    EntityRef creatureNearby(uint entry, float range) { return host.hostCreatureNearby(entry, range); }

    /// A creature of `entry` at `at` (zero: at the object), gone after `despawnMs` out of combat (0: when
    /// it dies), attacking `attack`.
    EntityRef summon(uint entry, Location at = Location.init, uint despawnMs = 0, EntityRef attack = EntityRef.init)
    {
        return host.hostSummon(entry, at, despawnMs, attack);
    }

    /// A creature here says `broadcast_text` row `text`.
    ActionResult sayAs(EntityRef speaker, uint text, EntityRef target = EntityRef.init)
    {
        return host.hostSayAs(speaker, text, target);
    }

    /// `KilledMonsterCredit` of `entry` for `player`.
    void killCredit(EntityRef player, uint entry) { host.hostKillCredit(player, entry); }
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

// Dungeon scripts:

/// A creature of the copy started fighting `enemy` (a boss pulled: its encounter begins).
struct CreatureEngaged
{
    EntityRef creature;
    EntityRef enemy;
}

/// A creature of the copy gave up its fight and goes home (a wipe).
struct CreatureEvaded
{
    EntityRef creature;
}

/// Scripted event `event` happened in the copy (`scripted_event_id`): a spell's `SEND_EVENT`, or a
/// goober's event, `source` (a player) using `target` (a game object, or nothing).
struct EventHappened
{
    uint event;
    EntityRef source;
    EntityRef target;
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
    // Dungeon scripts:
    EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack);
    ActionResult hostSay(EntityRef speaker, int textEntry, EntityRef target);
    ActionResult hostCast(EntityRef caster, uint spell, EntityRef target, bool triggered);
    ActionResult hostSetFaction(EntityRef creature, uint faction);
    ActionResult hostUnitFlags(EntityRef creature, uint flags, bool set);
    ActionResult hostAttack(EntityRef creature, EntityRef target);
    ActionResult hostMoveTo(EntityRef creature, Location at, uint point, bool run);
    ActionResult hostDespawn(EntityRef creature, uint delayMs);
    bool hostAlive(EntityRef creature);
    uint hostSpawnObjects(uint entry, uint despawnSeconds, Location near, float range);
    ActionResult hostObjectFlags(EntityRef object, uint set, uint clear);
    uint hostRandom(uint below);
    ActionResult hostRemoveAura(EntityRef creature, uint spell);
    EntityRef hostVictimOf(EntityRef creature);
    bool hostLocate(EntityRef who, out Location at);
    EntityRef hostAnyPlayer();
    void hostKillCreditAll(uint entry);
    bool hostChangeEntry(EntityRef creature, uint entry);
}

/// `GameObjectFlags`, as dungeon scripts set and clear them (`InstanceContext.objectFlags`).
enum ObjectFlag : uint
{
    inUse = 0x01,      /// in use: nobody else can use it now
    locked = 0x02,     /// it needs a key (a door opened by a script only)
    noInteract = 0x10, /// nobody can use it (a gong after the waves it called)
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

    /// A `Signal` for a creature's (or game object's) script in the copy.
    ActionResult signal(EntityRef to, uint id, int value = 0) { return host.hostSignal(to, id, value); }

    /// The players in the copy.
    @property uint playerCount() { return host.hostPlayerCount(); }

    /// A line in the server's log, naming the copy.
    void log(string text) { host.hostLog(text); }

    // Dungeon scripts:

    /// A creature of `entry` at `at`, gone after `despawnMs` out of combat (0: when it dies), attacking
    /// `attack`; nothing if it could not be made.
    EntityRef summon(uint entry, Location at, uint despawnMs = 0, EntityRef attack = EntityRef.init)
    {
        return host.hostSummon(entry, at, despawnMs, attack);
    }

    /// A creature of the copy says (yells, emotes) the `script_texts` row `entry` (negative).
    ActionResult say(EntityRef speaker, int entry, EntityRef target = EntityRef.init)
    {
        return host.hostSay(speaker, entry, target);
    }

    /// A creature of the copy casts `spell` at `target` (itself if nothing).
    ActionResult castSpell(EntityRef caster, uint spell, EntityRef target = EntityRef.init, bool triggered = true)
    {
        return host.hostCast(caster, spell, target ? target : caster, triggered);
    }

    /// A creature's faction, until it respawns (0: its template's again).
    ActionResult setFaction(EntityRef creature, uint faction) { return host.hostSetFaction(creature, faction); }

    /// Sets (or clears) a creature's `UnitFlag`s.
    ActionResult unitFlags(EntityRef creature, uint flags, bool set = true)
    {
        return host.hostUnitFlags(creature, flags, set);
    }

    /// A creature attacks `target`.
    ActionResult attack(EntityRef creature, EntityRef target) { return host.hostAttack(creature, target); }

    /// A creature walks (runs) to `at`; its script hears `MovementDone(point)` on arrival.
    ActionResult moveTo(EntityRef creature, Location at, uint point = 0, bool run = false)
    {
        return host.hostMoveTo(creature, at, point, run);
    }

    /// A creature goes away (to come back after its respawn time; a summon for good) in `delayMs`.
    ActionResult despawn(EntityRef creature, uint delayMs = 0) { return host.hostDespawn(creature, delayMs); }

    /// Whether a creature (or player) of the copy is alive (one not here counts as dead).
    bool alive(EntityRef creature) { return host.hostAlive(creature); }

    /// Every game object of `entry` of the dungeon (within `range` yards of `near`, if a range is
    /// given) not in the world is put there (a chest, a rocket); one not there by default goes again
    /// after `despawnSeconds`. How many came.
    uint spawnObjects(uint entry, uint despawnSeconds = 3600, Location near = Location.init, float range = 0)
    {
        return host.hostSpawnObjects(entry, despawnSeconds, near, range);
    }

    /// Sets a game object's `ObjectFlag`s `set` and clears those of `clear`.
    ActionResult objectFlags(EntityRef object, uint set, uint clear = 0)
    {
        return host.hostObjectFlags(object, set, clear);
    }

    /// A random number below `below`.
    uint random(uint below) { return host.hostRandom(below); }

    /// For `EventHappened`: the script handled the event; its database script does not run.
    void consume() { consumed_ = true; }

    /// Whether a handler called `consume`.
    @property bool consumed() const { return consumed_; }

    private bool consumed_;

    /// Takes the auras of `spell` off a creature (a statue's stone skin).
    ActionResult removeAura(EntityRef creature, uint spell) { return host.hostRemoveAura(creature, spell); }

    /// Whom a creature fights; nothing if it does not (or is not here).
    EntityRef victimOf(EntityRef creature) { return host.hostVictimOf(creature); }

    /// Where an entity of the copy is; false if it is not here.
    bool locate(EntityRef who, out Location at) { return host.hostLocate(who, at); }

    /// A living player of the copy that may be attacked (the first found); nothing if none.
    EntityRef anyPlayer() { return host.hostAnyPlayer(); }

    /// `KilledMonsterCredit` of `entry` for every player of the copy (whose quests want it).
    void killCreditAll(uint entry) { host.hostKillCreditAll(entry); }

    /// A creature of the copy becomes a creature of `entry` (Old Ironbark redeemed); false if it cannot.
    bool changeEntry(EntityRef creature, uint entry) { return host.hostChangeEntry(creature, entry); }
}

unittest
{
    const creature = EntityRef(0xF130_0002_8600_0123); // entry 646 (0x286), spawn 0x123
    assert(creature.isCreature && !creature.isPlayer && creature.entry == 646);
    assert(EntityRef(7).isPlayer && EntityRef(7).entry == 0 && !EntityRef.init);
    assert(Damaged(EntityRef.init, 10, 70, 60).crossed(66) && !Damaged(EntityRef.init, 10, 66, 60).crossed(66));
}

// ---------------------------------------------------------------------------
// Spell scripts (`@spell`, bound by `spell_scripts.ScriptName`), one per spell
// ---------------------------------------------------------------------------

/// A dummy or script effect of the spell (`effect`, its index; `value`, its amount) hit `target`.
/// `SpellContext.consume` keeps the spell's database script from running too.
struct EffectHit
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
    int value;
}

/// An aura of the spell (its effect `effect`, of `amount`) went onto `target`.
struct AuraApplied
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
    int amount;
}

/// A periodic effect of the spell's aura on `target` ticks: the `tick`th of `ticks`, of `amount`.
/// `SpellContext.setAmount` changes what this tick does.
struct AuraTicked
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
    uint tick;
    uint ticks;
    int amount;
}

/// The core's side of a spell script's context (the caster's session, or creature, implements it).
interface SpellHost
{
    uint hostSpellId();
    ActionResult hostCastFrom(EntityRef caster, uint spell, EntityRef target, bool triggered);
    ActionResult hostDamage(EntityRef target, uint amount);
    ActionResult hostEnergize(EntityRef target, ubyte power, int amount);
    uint hostHealth(EntityRef who);
    void hostQuestEvent(EntityRef player, uint quest);
    void hostKillCredit(EntityRef player, uint entry);
    EntityRef hostSummonAt(uint entry, Location at, uint despawnMs, EntityRef attack);
    ActionResult hostSignalCreature(EntityRef to, uint id, int value);
    void hostLog(string text);
    ActionResult hostModifyThreat(EntityRef creature, EntityRef target, int percent);
}

/// `Powers`, as scripts use them.
enum Power : ubyte
{
    mana = 0,
    rage = 1,
    focus = 2,
    energy = 3,
}

/// A spell script's handle on the cast, for the length of one handler.
struct SpellContext
{
    private SpellHost host;
    private bool consumed_;
    private bool amountSet;
    private int amount_;

    @disable this(this);

    /// The core makes one around a cast.
    this(SpellHost host) pure nothrow @nogc @safe
    {
        this.host = host;
    }

    /// The spell.
    @property uint spellId() { return host.hostSpellId(); }

    /// `caster` (the spell's caster, or a creature it controls here) casts `spell` at `target`.
    ActionResult castSpell(EntityRef caster, uint spell, EntityRef target, bool triggered = true)
    {
        return host.hostCastFrom(caster, spell, target, triggered);
    }

    /// Damage to `target` (`DealDamage`), shown as the spell's.
    ActionResult damage(EntityRef target, uint amount) { return host.hostDamage(target, amount); }

    /// Power for `target`, shown as the spell's (negative: taken).
    ActionResult energize(EntityRef target, Power power, int amount) { return host.hostEnergize(target, power, amount); }

    /// A unit's health; 0 if it is not here.
    uint health(EntityRef who) { return host.hostHealth(who); }

    /// `AreaExploredOrEventHappens` for `player`.
    void questEvent(EntityRef player, uint quest) { host.hostQuestEvent(player, quest); }

    /// `KilledMonsterCredit` of `entry` for `player`.
    void killCredit(EntityRef player, uint entry) { host.hostKillCredit(player, entry); }

    /// A creature of `entry` at `at` (zero: near the caster), gone after `despawnMs` (0: when it dies).
    EntityRef summon(uint entry, Location at = Location.init, uint despawnMs = 0, EntityRef attack = EntityRef.init)
    {
        return host.hostSummonAt(entry, at, despawnMs, attack);
    }

    /// A `Signal` for a creature's script (on another node: sent there).
    ActionResult signal(EntityRef to, uint id, int value = 0) { return host.hostSignalCreature(to, id, value); }

    /// A line in the server's log.
    void log(string text) { host.hostLog(text); }

    /// `ModifyThreatPercent`: `target`'s threat on `creature` changes by `percent` (-100: none left).
    ActionResult modifyThreat(EntityRef creature, EntityRef target, int percent)
    {
        return host.hostModifyThreat(creature, target, percent);
    }

    /// For `AuraTicked`: what this tick does instead.
    void setAmount(int amount)
    {
        amountSet = true;
        amount_ = amount;
    }

    /// Whether a handler set the amount, and to what.
    @property bool amountChanged() const { return amountSet; }
    /// ditto
    @property int amount() const { return amount_; }

    /// The script did what the effect does; the spell's database script does not run.
    void consume() { consumed_ = true; }

    /// Whether a handler called `consume`.
    @property bool consumed() const { return consumed_; }
}

// ---------------------------------------------------------------------------
// Area trigger scripts (`@areaTrigger`, bound by `scripted_areatrigger`), one per trigger
// ---------------------------------------------------------------------------

/// A player walked into area trigger `trigger`, whose centre is `at`. `consume` keeps the trigger's
/// usual effects (its teleport, its quest) from following.
struct TriggerEntered
{
    EntityRef player;
    uint trigger;
    Location at;
}

/// The core's side of an area trigger script's context (the player's session implements it).
interface AreaTriggerHost
{
    QuestProgress hostQuestStatusOf(EntityRef player, uint quest);
    void hostQuestEvent(EntityRef player, uint quest);
    EntityRef hostSummonAt(uint entry, Location at, uint despawnMs, EntityRef attack);
    EntityRef hostCreatureNear(uint entry, Location at, float range);
    ActionResult hostCastFrom(EntityRef caster, uint spell, EntityRef target, bool triggered);
    void hostSignalDungeon(uint id, int value);
    void hostLog(string text);

    // Eastern Kingdoms scripts:
    void hostKillCreditAt(EntityRef player, uint entry);
    ActionResult hostSayAt(EntityRef speaker, int entry, EntityRef target);
    // Dungeon scripts:
    bool hostHasItem(EntityRef player, uint item);
}

/// An area trigger script's handle, for the length of one handler.
struct AreaTriggerContext
{
    private AreaTriggerHost host;
    private bool consumed_;

    @disable this(this);

    /// The core makes one around the player who walked in.
    this(AreaTriggerHost host) pure nothrow @nogc @safe
    {
        this.host = host;
    }

    /// Where `player` stands with `quest`.
    QuestProgress questStatus(EntityRef player, uint quest) { return host.hostQuestStatusOf(player, quest); }

    /// `AreaExploredOrEventHappens` for `player`.
    void questEvent(EntityRef player, uint quest) { host.hostQuestEvent(player, quest); }

    /// A creature of `entry` at `at`, gone after `despawnMs` out of combat (0: when it dies), attacking `attack`.
    EntityRef summon(uint entry, Location at, uint despawnMs = 0, EntityRef attack = EntityRef.init)
    {
        return host.hostSummonAt(entry, at, despawnMs, attack);
    }

    /// A living creature of `entry` within `range` yards of `at`; nothing if none.
    EntityRef creatureNear(uint entry, Location at, float range) { return host.hostCreatureNear(entry, at, range); }

    /// `caster` (the player, or a creature here) casts `spell` at `target`.
    ActionResult castSpell(EntityRef caster, uint spell, EntityRef target, bool triggered = true)
    {
        return host.hostCastFrom(caster, spell, target, triggered);
    }

    /// A `Signal` for the dungeon's script, if the trigger is in a dungeon copy.
    void signalDungeon(uint id, int value = 0) { host.hostSignalDungeon(id, value); }

    /// A line in the server's log.
    void log(string text) { host.hostLog(text); }

    // Dungeon scripts:

    /// Whether `player` carries item `item` (a key, a seal; the bank does not count).
    bool hasItem(EntityRef player, uint item) { return host.hostHasItem(player, item); }

    /// The script handled the trigger; its usual effects do not follow.
    void consume() { consumed_ = true; }

    /// Whether a handler called `consume`.
    @property bool consumed() const { return consumed_; }

    // Eastern Kingdoms scripts:

    /// `KilledMonsterCredit` of `entry` for `player`.
    void killCredit(EntityRef player, uint entry) { host.hostKillCreditAt(player, entry); }

    /// A creature here says the `script_texts` row `entry` (negative), with its sound and emote.
    ActionResult say(EntityRef speaker, int entry, EntityRef target = EntityRef.init)
    {
        return host.hostSayAt(speaker, entry, target);
    }
}
