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
    uint schoolMask; /// Raid scripts: the schools it struck with (`SpellSchoolMask`: 1 physical, 4 fire, 8 nature, 16 frost, ...)
}

/// This creature finished a cast and resolved its spell effects.
struct CreatureCastFinished
{
    uint spell;
}

/// A spell landed and restored some of this creature's health.
struct CreatureHealed
{
    uint spell;
}

// Instance round 2:

/// Its aura of `spell`, from `caster`, went: it ran out, was dispelled or cancelled, or a script took it away
/// (not when it died).
struct AuraRemoved
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

// Kalimdor scripts:

/// `UnitFlags` a script sets or clears (`CreatureContext.unitFlags`).
enum UnitFlag : uint
{
    notAttackable = 0x0000_0002,
    immuneToPlayer = 0x0000_0100,
    immuneToNpc = 0x0000_0200,
    untargetable = 0x0001_0000,
    pacified = 0x0002_0000, /// Raid scripts
    stunned = 0x0004_0000,  /// Raid scripts
    uninteractible = 0x0200_0000,
}

/// Factions (`FactionTemplate`) escorted creatures take on their way (`FACTION_ESCORT_*`): the
/// side (alliance, horde, neutral) whose creatures are friendly, and whether those of the surroundings
/// hostile to them attack them on sight (active) or not (passive).
enum EscortFaction : uint
{
    allianceNeutralPassive = 10,
    hordeNeutralPassive = 33,
    neutralNeutralPassive = 113,
    allianceNeutralActive = 231,
    hordeNeutralActive = 232,
    neutralNeutralActive = 250,
    neutralFriendPassive = 290,
    neutralFriendActive = 495,
    alliancePassive = 774,
    hordePassive = 775,
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

/// A stealthed unit came near enough to put it on its guard, not near enough to be seen (CMaNGOS's
/// `AI_EVENT_...` stealth alert: a lookout turns and calls out).
struct StealthAlert
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
    uint hostHealthOf(EntityRef who);
    bool hostInMeleeReach(EntityRef who);
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
    // Kalimdor scripts:
    ActionResult hostFactionOf(EntityRef creature, uint faction);
    ActionResult hostUnitFlagsOf(EntityRef creature, uint flags, bool set);
    void hostFollow(EntityRef leader, float distance, float angle);
    ActionResult hostCastAs(EntityRef caster, uint spell, EntityRef target, bool triggered);
    ActionResult hostObjectUsable(EntityRef object, bool usable);
    uint hostEntryOf(EntityRef who);
    void hostGroupQuestEvent(EntityRef player, uint quest);
    bool hostLocationOf(EntityRef who, out Location at);
    void hostEmoteState(uint emote);
    size_t hostCreaturesNearby(uint entry, float range, EntityRef[] found);
    EntityRef hostOwner();
    uint hostItemCount(EntityRef player, uint item);
    uint hostGiveItem(EntityRef player, uint item, uint count);
    // Dungeon scripts:
    EntityRef hostPlayerNearby(float range);

    // Raid scripts:
    int hostAskDungeon(uint id);
    EntityRef hostSelectTarget(Pick pick, uint filter, uint skip);
    size_t hostThreatList(EntityRef[] into);
    ActionResult hostModifyThreat(EntityRef target, int percent);
    size_t hostPlayersNear(float range, EntityRef[] into);
    void hostTeleport(Location at);
    void hostZoneCombat();
    bool hostCasting();
    void hostInterrupt();
    void hostFlying(bool on);
    void hostDisplay(uint model);
    void hostSetHealthPercent(EntityRef who, uint percent);
    void hostRooted(bool on);
    void hostAddThreat(EntityRef who, float amount);
    void hostMoveNow(Location at, uint point, bool run);
    void hostSpellList(uint id);
    ubyte hostClassOf(EntityRef who);

    // Instance round 2:
    ActionResult hostTeleportPlayer(EntityRef player, Location at);
    ActionResult hostMovementScriptOf(EntityRef creature, uint id);
    float hostThreatOf(EntityRef who);

    // Open-world round 2:
    uint hostLevelOf(EntityRef who);
    uint hostSkillOf(EntityRef player, uint skill);
    bool hostKnowsSpell(EntityRef player, uint spell);
    Standing hostStandingOf(EntityRef player, uint faction);
    bool hostWearsItemNeeding(EntityRef player, uint spell);
    bool hostTakeMoney(EntityRef player, uint copper);
    void hostUnlearnSpell(EntityRef player, uint spell);
    void hostOpenWindow(EntityRef player, NpcWindow window);
    void hostZoneUnderAttack(EntityRef attacker);
    void hostWalkPath(uint pathId);
    ActionResult hostSendHome(EntityRef creature);

    // The war effort:
    void hostWarEffortHandIn(uint quest, uint resource);
    void hostWarEffortColossus(uint colossus);
}

// Open-world round 2:

/// Where a player stands with a faction (`ReputationRank`).
enum Standing : ubyte
{
    hated,
    hostile,
    unfriendly,
    neutral,
    friendly,
    honored,
    revered,
    exalted,
}

/// A window of an NPC's service a script opens for a player (`CreatureContext.openWindow`).
enum NpcWindow : ubyte
{
    vendor,  /// its goods (`SEND_VENDORLIST`)
    trainer, /// its training (`SEND_TRAINERLIST`)
}

/**
 * A creature script's handle on its creature and the world, for the length of one handler. It
 * cannot be copied or kept: what persists is the script's own state.
 */
interface ScourgeCampHost
{
    bool hostDisruptEngineer(EntityRef player);
    long hostInvasionCampaign(out uint generation);
    void hostCampDefeated(long campaign, uint generation);
}

struct CreatureContext
{
    bool disruptEngineer(EntityRef player)
    {
        auto camp = cast(ScourgeCampHost) host;
        return camp !is null && camp.hostDisruptEngineer(player);
    }
    long invasionCampaign(out uint generation)
    {
        auto camp = cast(ScourgeCampHost) host;
        return camp is null ? 0 : camp.hostInvasionCampaign(generation);
    }
    void campDefeated(long campaign, uint generation)
    {
        if (auto camp = cast(ScourgeCampHost) host)
            camp.hostCampDefeated(campaign, generation);
    }
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

    /// Another unit's current HP. Absent units have zero HP.
    uint healthOf(EntityRef who) { return host.hostHealthOf(who); }

    /// Whether the creature can reach this unit with a melee swing.
    bool inMeleeReach(EntityRef who) { return host.hostInMeleeReach(who); }

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

    /// A `Signal` for its dungeon's script (outside a dungeon: its continent's world map script, if any).
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

    /// Whether `who` (itself, another creature or a player here) has `spell`'s aura.
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

    // Raid scripts:

    /// Its dungeon script's answer to question `id` (`Asked`); 0 outside a dungeon or unanswered.
    int askDungeon(uint id) { return host.hostAskDungeon(id); }

    /// One of those it fights, picked by `pick` among those `filter` (`PickFilter` bits) lets through,
    /// the first `skip` passed over (the second most hated: `Pick.topThreat`, skip 1); nothing if none.
    EntityRef selectTarget(Pick pick, uint filter = 0, uint skip = 0) { return host.hostSelectTarget(pick, filter, skip); }

    /// Those it fights (its threat list), most hated first, as many as `into` holds; how many were written.
    size_t threatList(EntityRef[] into) { return host.hostThreatList(into); }

    /// `target`'s threat on it changes by `percent` (-100: none left; it stays on the list).
    ActionResult modifyThreat(EntityRef target, int percent) { return host.hostModifyThreat(target, percent); }

    /// Everyone's threat on it gone (`DoResetThreat`).
    void resetThreat() { host.hostModifyThreat(EntityRef.init, -100); }

    /// The living players within `range` yards, as many as `into` holds.
    size_t playersNear(float range, EntityRef[] into) { return host.hostPlayersNear(range, into); }

    /// It is at `at` at once (`NearTeleportTo`), on its map.
    void teleport(Location at) { host.hostTeleport(at); }

    /// In a dungeon: every living player of the copy joins its fight (`DoZoneInCombat`).
    void zoneCombat() { host.hostZoneCombat(); }

    /// Whether it is casting a spell.
    @property bool casting() { return host.hostCasting(); }

    /// Its spell being cast is stopped.
    void interrupt() { host.hostInterrupt(); }


    // Kalimdor scripts:

    /// Another creature here takes faction `faction` (0: its template's).
    ActionResult setFactionOf(EntityRef creature, uint faction) { return host.hostFactionOf(creature, faction); }

    /// Sets (or clears) unit flags of another creature here.
    ActionResult unitFlagsOf(EntityRef creature, uint flags, bool set = true)
    {
        return host.hostUnitFlagsOf(creature, flags, set);
    }

    /// Follows `leader` (a player or a creature), `distance` yards off at `angle` radians from its facing;
    /// nothing: stops following and stands.
    void follow(EntityRef leader, float distance = 2.5f, float angle = 1.5708f)
    {
        host.hostFollow(leader, distance, angle);
    }

    /// Another creature here casts `spell` at `target`.
    ActionResult castAs(EntityRef caster, uint spell, EntityRef target, bool triggered = false)
    {
        return host.hostCastAs(caster, spell, target, triggered);
    }

    /// It flies (`moveTo` flies it, and it hovers where it stops), or walks again.
    void flying(bool on) { host.hostFlying(on); }

    /// It looks like model `model` (0: its own again).
    void display(uint model) { host.hostDisplay(model); }

    /// A creature's health (its own by default) set to `percent` of its most.
    void setHealthPercent(uint percent, EntityRef who = EntityRef.init)
    {
        host.hostSetHealthPercent(who ? who : host.hostSelf(), percent);
    }

    /// Held in place (it still turns and casts), or free to move again.
    void rooted(bool on) { host.hostRooted(on); }

    /// Threat of `who` (a unit here) on it, added (its list takes it in if it was not there).
    void addThreat(EntityRef who, float amount) { host.hostAddThreat(who, amount); }

    /// As `moveTo`, but at once even in a fight (turn its combat movement off first, or it chases its
    /// victim again): a dragon taking to the air, a boss going to its place.
    void moveNow(Location at, uint point, bool run = true) { host.hostMoveNow(at, point, run); }

    /// The spells it casts by itself in a fight: `creature_spell_list` `id` from now (0: its template's).
    void spellList(uint id) { host.hostSpellList(id); }

    /// A player's class (`Classes`: 1 warrior .. 11 druid); 0 for anyone else.
    ubyte classOf(EntityRef who) { return host.hostClassOf(who); }

    /// Whether players may use a game object here (`GO_FLAG_NO_INTERACT` cleared or set).
    ActionResult objectUsable(EntityRef object, bool usable) { return host.hostObjectUsable(object, usable); }

    /// The entry of a creature or object here (its current one, after a `changeEntry`); 0 if not here.
    uint entryOf(EntityRef who) { return host.hostEntryOf(who); }

    /// `RewardPlayerAndGroupAtEventExplored`: the event of `quest` for `player` and the members of its group
    /// near it (within 100 yards of the creature).
    void groupQuestEvent(EntityRef player, uint quest) { host.hostGroupQuestEvent(player, quest); }

    /// Where another unit or object on its map is; false if it is not seen here.
    bool locationOf(EntityRef who, out Location at) { return host.hostLocationOf(who, at); }

    /// The emote it keeps playing (`EMOTE_STATE_*`: 234 chopping wood, 173 working; 0: none).
    void emoteState(uint emote) { host.hostEmoteState(emote); }

    /// The living creatures of `entry` within `range` yards, as many as `found` holds; how many were put there.
    size_t creaturesNearby(uint entry, float range, EntityRef[] found) { return host.hostCreaturesNearby(entry, range, found); }

    /// Whose it is: the player whose pet it is, or whoever summoned it; nothing for a creature of its own.
    @property EntityRef owner() { return host.hostOwner(); }

    /// How many of `item` a player here carries (its bank not counted).
    uint itemCount(EntityRef player, uint item) { return host.hostItemCount(player, item); }

    /// Gives a player here `count` of `item`, into its bags as far as they hold; how many it got.
    uint giveItem(EntityRef player, uint item, uint count = 1) { return host.hostGiveItem(player, item, count); }
    // Dungeon scripts:

    /// The nearest living player within `range` yards that may be attacked; nothing if none.
    EntityRef playerNearby(float range) { return host.hostPlayerNearby(range); }

    // Instance round 2:

    /// `player` (here) is at `at` at once, on this map (C'Thun swallowing a player).
    ActionResult teleport(EntityRef player, Location at) { return host.hostTeleportPlayer(player, at); }

    /// Runs `dbscripts_on_creature_movement` script `id` on another creature here (as its waypoint's script
    /// runs: a summoned imp walked along its path by this script).
    ActionResult movementScript(EntityRef creature, uint id) { return host.hostMovementScriptOf(creature, id); }

    /// `who`'s threat on it (0 if `who` is not on its threat list).
    float threatOf(EntityRef who) { return host.hostThreatOf(who); }

    // Open-world round 2:

    /// A unit's level (a player's or a creature's here); 0 if it is not here.
    uint levelOf(EntityRef who) { return host.hostLevelOf(who); }

    /// A player's value in skill `skill` (`SkillLine`: 164 blacksmithing, 165 leatherworking), without
    /// what auras and items add; 0 if it does not have the skill (or is not here).
    uint skillOf(EntityRef player, uint skill) { return host.hostSkillOf(player, skill); }

    /// Whether a player here knows `spell` (its spellbook: a profession's specialization, a recipe).
    bool knowsSpell(EntityRef player, uint spell) { return host.hostKnowsSpell(player, spell); }

    /// Where a player stands with `faction` (`Faction.dbc`); hated if it is not here.
    Standing standingOf(EntityRef player, uint faction) { return host.hostStandingOf(player, faction); }

    /// Whether a player wears an item that needs `spell` to be worn (`item_template.requiredspell`).
    bool wearsItemNeeding(EntityRef player, uint spell) { return host.hostWearsItemNeeding(player, spell); }

    /// Takes `copper` from a player's money; false (and nothing taken) if it has less, or is not here.
    bool takeMoney(EntityRef player, uint copper) { return host.hostTakeMoney(player, copper); }

    /// A player forgets `spell`, and the recipes taught by the items that need it (a specialization's).
    void unlearnSpell(EntityRef player, uint spell) { host.hostUnlearnSpell(player, spell); }

    /// Opens a window of its services for a player (its goods, its training), as its menu's option would.
    void openWindow(EntityRef player, NpcWindow window) { host.hostOpenWindow(player, window); }

    /// Its zone is under attack by `attacker` (a player, or a pet): the players of its side are told
    /// (`SMSG_ZONE_UNDER_ATTACK`, the defense channels).
    void zoneUnderAttack(EntityRef attacker) { host.hostZoneUnderAttack(attacker); }

    /// Walks its waypoint path (`creature_movement`, or its entry's `creature_movement_template`), as a
    /// creature spawned to do so does (`MoveWaypoint`); nothing if it has none. `pathId`: its entry's
    /// path of that id instead (`creature_movement_template.PathId`).
    void walkPath(uint pathId = 0) { host.hostWalkPath(pathId); }

    /// It (or another creature here) not fighting goes back where it belongs, and moves as it did
    /// before (`EnterEvadeMode` out of a fight, `MoveTargetedHome`).
    ActionResult sendHome(EntityRef creature = EntityRef.init) { return host.hostSendHome(creature ? creature : host.hostSelf()); }

    // The war effort (the server-wide state that opens Ahn'Qiraj, `dmangos.world.wareffort`):

    /**
     * What quest `quest` asked for (its first required item's count) was handed in, and counts for the war
     * effort as `resource` (`AQResources`' order: 0 Peacebloom .. 29 the Horde's Runecloth Bandages), while
     * the effort gathers. It counts once, server-wide, wherever the effort's state is kept.
     */
    void warEffortHandIn(uint quest, uint resource) { host.hostWarEffortHandIn(quest, resource); }

    /// A Colossus of Silithus fell (0 Ashi, 1 Regal, 2 Zora): the war effort remembers it, server-wide.
    void warEffortColossusFell(uint colossus) { host.hostWarEffortColossus(colossus); }
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
    // Kalimdor scripts:
    Location hostObjectLocation();
    ActionResult hostObjectSignal(EntityRef to, uint id, int value);
    ActionResult hostObjectCast(EntityRef caster, uint spell, EntityRef target);
    size_t hostObjectCreaturesNear(uint entry, float range, EntityRef[] found);

    // Raid scripts:
    int hostAskDungeon(uint id);
    void hostPulseTrap();

    // Open-world round 2:
    void hostCustomAnim();
    void hostPlaySound(uint sound, bool music);
    ActionResult hostMoveCreature(EntityRef creature, Location at, uint point, bool run);
    ActionResult hostSendHome(EntityRef creature);
    bool hostHasItem(EntityRef player, uint item);
    uint hostRandom(uint below);
    uint hostMinuteOfDay();
    uint hostAreaId();

    // The war effort:
    uint hostWarEffortPhase();
    void hostWarEffortGong(EntityRef player);
    ActionResult hostZoneNotice(uint text);
}

// Open-world round 2:

/**
 * A unit (a player) comes within reach of it, a trap, and sets it off (`pTrapSearching`): the trap's
 * spell follows unless `GameObjectContext.consume` keeps it from springing for this unit.
 */
struct TrapSprung
{
    EntityRef unit;
}

/// A player successfully disarmed a trap. The script can consume its usual removal.
struct TrapDisarmed
{
    EntityRef player;
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

    // Kalimdor scripts:

    /// Where it is.
    @property Location location() { return host.hostObjectLocation(); }

    /// A `Signal` for a creature's script (on another node: sent there).
    ActionResult signal(EntityRef to, uint id, int value = 0) { return host.hostObjectSignal(to, id, value); }

    /// `caster` (the player using it, or a creature here) casts `spell` at `target`, triggered.
    ActionResult castSpell(EntityRef caster, uint spell, EntityRef target)
    {
        return host.hostObjectCast(caster, spell, target);
    }

    /// The living creatures of `entry` within `range` yards of it, as many as `found` holds; how many were put there.
    size_t creaturesNearby(uint entry, float range, EntityRef[] found)
    {
        return host.hostObjectCreaturesNear(entry, range, found);
    }
    // Raid scripts:

    /// Its dungeon script's answer to question `id` (`Asked`); 0 outside a dungeon or unanswered.
    int askDungeon(uint id) { return host.hostAskDungeon(id); }

    /// Apply this trap's area aura to eligible players within the spell's radius.
    void pulseTrap() { host.hostPulseTrap(); }

    // Open-world round 2:

    /// Plays its custom animation for those who see it (a lightning bolt's flash).
    void customAnim() { host.hostCustomAnim(); }

    /// Plays sound `sound` (`SoundEntries.dbc`) from it for the players who see it; `music`: as music
    /// (`SMSG_PLAY_MUSIC`), which the client fades with its music volume.
    void playSound(uint sound, bool music = false) { host.hostPlaySound(sound, music); }

    /// A creature here runs (walks) to `at`; one fighting is not distracted (`notAllowed`).
    ActionResult moveCreature(EntityRef creature, Location at, uint point = 0, bool run = true)
    {
        return host.hostMoveCreature(creature, at, point, run);
    }

    /// A creature here not fighting goes back where it belongs (`EnterEvadeMode`).
    ActionResult sendHome(EntityRef creature) { return host.hostSendHome(creature); }

    /// Whether a player here carries `item` (its bank not counted).
    bool hasItem(EntityRef player, uint item) { return host.hostHasItem(player, item); }

    /// A random number below `below`.
    uint random(uint below) { return host.hostRandom(below); }

    /// The server's local time of day, in minutes since midnight (the bells toll the hours).
    @property uint minuteOfDay() { return host.hostMinuteOfDay(); }

    /// The area (`AreaTable.dbc`) it stands in, as the map's terrain has it; 0 if unknown.
    @property uint areaId() { return host.hostAreaId(); }

    // The war effort (`dmangos.world.wareffort`):

    /**
     * The war effort's phase as this server last heard it: 0 not begun, 1 gathering, 2 carrying the
     * supplies, 3 the gong's time, 4 the ten-hour war, 5 done.
     */
    @property uint warEffortPhase() { return host.hostWarEffortPhase(); }

    /// `player` rang the Scarab Gong: the ten-hour war begins, if it is the gong's time (once, server-wide).
    void warEffortGong(EntityRef player) { host.hostWarEffortGong(player); }

    /// `broadcast_text` row `text` as a notice (`CHAT_MSG_BG_SYSTEM_NEUTRAL`) to the players in its zone.
    ActionResult zoneNotice(uint text) { return host.hostZoneNotice(text); }
}

// ---------------------------------------------------------------------------
// Dungeon scripts (`@instance`, bound by `instance_template.ScriptName`), one per copy
// ---------------------------------------------------------------------------

/// A creature of the copy came into the world (its cell loaded, or it respawned).
struct CreatureLoaded
{
    EntityRef creature;
    bool summoned;
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
    bool summoned; /// Open-world round 2: it was summoned (a script's, a spell's), not a spawn of the map's
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

/**
 * The copy's script was made again from its saved state (`instance.data`): the server restarted, or
 * the copy was unloaded and is entered again. Raised once, before any of its creatures or objects
 * load. What was under way when the state was saved is not any more (its creatures, summons and
 * timers went with the old world): an encounter in progress starts again from the beginning, as
 * ScriptDev's `Load` turns `IN_PROGRESS` into `NOT_STARTED`. Not raised for a copy that arrives
 * from another node with its creatures (their fights go on there).
 */
struct Restored
{
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
    void hostSignalObjects(uint entry, uint id, int value);
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
    uint hostUnitFlagsOf(EntityRef creature);
    bool hostLocationOf(EntityRef who, out Location at);
    EntityRef hostAnyPlayer();
    void hostKillCreditAll(uint entry);
    bool hostChangeEntry(EntityRef creature, uint entry);
    // Raid scripts:
    ActionResult hostDespawnObject(EntityRef object);
    bool hostRespawnObject(uint entry, uint seconds);
    ActionResult hostUseObject(EntityRef object);
    size_t hostPlayers(EntityRef[] into);
    ActionResult hostZoneCombat(EntityRef creature);
    EntityRef hostSummonObject(uint entry, Location at, uint seconds);
    size_t hostCreaturesNear(Location at, uint entry, float range, EntityRef[] into);
    // Dungeons round 2:
    ActionResult hostWalkPath(EntityRef creature, uint pathId);
    bool hostHasAura(EntityRef creature, uint spell);
    bool hostEntryKilled(uint entry);
    void hostStartDatabaseEvent(uint event, EntityRef source, EntityRef target);
    void hostRespawnKilled(uint entry);
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
    private bool checkpoint_, waitForPlayer_;
    private EntityRef[] summons_, releasedActors_;
    private const(EntityRef)[] savedSummons_;

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

    /// A `Signal` for every loaded game object of `entry` in the copy.
    void signalObjects(uint entry, uint id, int value = 0) { host.hostSignalObjects(entry, id, value); }

    /// The players in the copy.
    @property uint playerCount() { return host.hostPlayerCount(); }

    /// A line in the server's log, naming the copy.
    void log(string text) { host.hostLog(text); }

    /// Make this handler's saved state durable before continuing on a cluster worker.
    void checkpoint() { checkpoint_ = true; }
    package(dmangos) @property bool checkpointRequested() const { return checkpoint_; }

    /// On restoration, hold the saved timers until the first player comes back.
    void waitForPlayer() { waitForPlayer_ = true; }
    package(dmangos) @property bool waitingForPlayer() const { return waitForPlayer_; }

    /// Include a living encounter creature in the copy's durable checkpoints.
    void checkpointCreature(EntityRef creature)
    {
        summons_ ~= creature;
        checkpoint();
    }

    /// Include a spawned encounter object, with its current state and removal deadline.
    void checkpointObject(EntityRef object)
    {
        summons_ ~= object;
        checkpoint();
    }

    /// Stop saving an encounter creature or object after its temporary state ends.
    void releaseCheckpointActor(EntityRef actor)
    {
        releasedActors_ ~= actor;
        checkpoint();
    }

    private const(uint)[] databaseScripts_;
    private bool changedDatabaseScripts_;

    /// Keep the pending steps of these database script IDs with the encounter checkpoint.
    void checkpointDatabaseScripts(const(uint)[] scripts)
    {
        databaseScripts_ = scripts.dup;
        changedDatabaseScripts_ = true;
        checkpoint();
    }

    /// Take over an event's default database steps so they can be saved with this handler's state.
    void checkpointEvent(const ref EventHappened event)
    {
        host.hostStartDatabaseEvent(event.event, event.source, event.target);
        consume();
        checkpoint();
    }

    package(dmangos) @property bool changedDatabaseScripts() const { return changedDatabaseScripts_; }
    package(dmangos) @property const(uint)[] databaseScripts() const { return databaseScripts_; }

    /// Whether this creature was included in the checkpoint being restored.
    bool hasSavedCreature(EntityRef creature) const
    {
        foreach (saved; savedSummons_)
            if (saved == creature)
                return true;
        return false;
    }

    /// Finds a checkpointed creature type before the copy has loaded its spawns.
    bool hasSavedCreature(uint entry) const
    {
        foreach (saved; savedSummons_)
            if (saved.isCreature && saved.entry == entry)
                return true;
        return false;
    }

    /// Finds a checkpointed game object type before the copy has loaded its spawns.
    bool hasSavedGameObject(uint entry) const
    {
        foreach (saved; savedSummons_)
            if (saved.isGameObject && saved.entry == entry)
                return true;
        return false;
    }

    package(dmangos) @property EntityRef[] checkpointSummons() { return summons_; }
    package(dmangos) @property EntityRef[] releasedCheckpointActors() { return releasedActors_; }
    package(dmangos) @property void savedSummons(const(EntityRef)[] creatures) { savedSummons_ = creatures; }

    // Raid scripts:

    private bool answered_;
    private int answer_;

    /// For `Asked`: the answer.
    void answer(int value)
    {
        answered_ = true;
        answer_ = value;
    }

    /// Whether a handler answered, and what.
    @property bool answered() const { return answered_; }
    /// ditto
    @property int answerGiven() const { return answer_; }

    /// A game object goes (it comes back when its cell loads again).
    ActionResult despawnObject(EntityRef object) { return host.hostDespawnObject(object); }

    /// The game object of `entry` the copy's map has a spawn of (one not there by default) appears, for
    /// `seconds` (0: for good); false if there is no such spawn.
    bool respawnObject(uint entry, uint seconds = 0) { return host.hostRespawnObject(entry, seconds); }

    /// A door or button is used: it opens (or closes), and goes back by itself after its time.
    ActionResult useObject(EntityRef object) { return host.hostUseObject(object); }

    /// The players in the copy, as many as `into` holds.
    size_t players(EntityRef[] into) { return host.hostPlayers(into); }


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

    /// A creature of the copy fights every living player in it (`SetInCombatWithZone`).
    ActionResult zoneCombat(EntityRef creature) { return host.hostZoneCombat(creature); }

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

    /// A creature's current `UnitFlag`s, or zero if it is not here.
    uint unitFlagsOf(EntityRef creature) { return host.hostUnitFlagsOf(creature); }

    /// Where an entity of the copy is; false if it is not here.
    bool locationOf(EntityRef who, out Location at) { return host.hostLocationOf(who, at); }

    /// A living player of the copy that may be attacked (the first found); nothing if none.
    EntityRef anyPlayer() { return host.hostAnyPlayer(); }

    /// `KilledMonsterCredit` of `entry` for every player of the copy (whose quests want it).
    void killCreditAll(uint entry) { host.hostKillCreditAll(entry); }

    /// A creature of the copy becomes a creature of `entry` (Old Ironbark redeemed); false if it cannot.
    bool changeEntry(EntityRef creature, uint entry) { return host.hostChangeEntry(creature, entry); }

    /// A game object of `entry` at `at` in the copy (none of the map's spawns), gone after `seconds`
    /// (0: when the copy goes); nothing if there is no such object.
    EntityRef summonObject(uint entry, Location at, uint seconds = 0) { return host.hostSummonObject(entry, at, seconds); }

    /// The living creatures of `entry` (0: any) within `range` yards of `at`, as many as `into` holds.
    size_t creaturesNear(Location at, uint entry, float range, EntityRef[] into)
    {
        return host.hostCreaturesNear(at, entry, range, into);
    }

    /// A creature of the copy walks its entry's waypoint path `pathId` (`creature_movement_template`), its
    /// points' scripts run as it reaches them (`MoveWaypoint`: a suppressor from its door to the shade).
    ActionResult walkPath(EntityRef creature, uint pathId) { return host.hostWalkPath(creature, pathId); }

    /// Whether a creature of the copy has an aura of `spell` (false if it is not here).
    bool hasAura(EntityRef creature, uint spell) { return host.hostHasAura(creature, spell); }

    /// Whether a permanent spawn of this entry died in this copy.
    bool entryKilled(uint entry) { return host.hostEntryKilled(entry); }

    /// Restores this entry's killed spawns in the current copy.
    void respawnKilled(uint entry) { host.hostRespawnKilled(entry); }
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

// Spell scripts of items, quests and the world:

/// The spell is about to be cast at `target` (its unit target; nothing if none): `SpellContext.refuse`
/// makes the cast fail (CMaNGOS's `OnCheckCast`), as the spell's own rules would.
struct CastChecked
{
    EntityRef caster;
    EntityRef target;
}

/// The cast began (CMaNGOS's `OnSuccessfulStart`): its time runs, nothing of it happened yet.
struct CastStarted
{
    EntityRef caster;
    EntityRef target;
}

/// The spell's aura (its effect `effect`) is on `target`, five seconds more (CMaNGOS's `OnHeartbeat`: the
/// unit's heartbeat).
struct AuraHeartbeat
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
}

/// The spell's aura (its effect `effect`) went from `target`: its time ran out (`expired`), or it was cancelled, dispelled or
/// taken away (CMaNGOS's `OnApply` with `apply` false; its `AURA_REMOVE_BY_EXPIRE`).
struct AuraEnded
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
    bool expired;
}

/// The spell's effect `effect` is about to reach `target` (CMaNGOS's `OnCheckTarget`): `SpellContext.exclude` passes
/// it over. Asked of a creature's spells.
struct TargetChecked
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
}

/// A periodic effect of the spell's aura on `target` ticked, its work done (CMaNGOS's `OnPeriodicTickEnd`).
struct AuraTickEnded
{
    EntityRef caster;
    EntityRef target;
    ubyte effect;
}

/// Why a script refuses a cast (`SpellCastResult`, as the client shows it).
enum CastRefusal : ubyte
{
    badTargets = 0x0A,      /// SPELL_FAILED_BAD_TARGETS: "Invalid target"
}

/// The spell was cast at `target` (before its hits are rolled: CMaNGOS's `OnCast`).
struct SpellCast
{
    EntityRef caster;
    EntityRef target;
}

/// The spell reached `target`: hit, or not (`missed`: it missed, was dodged, parried, resisted...; `OnHit`).
struct SpellLanded
{
    EntityRef caster;
    EntityRef target;
    bool missed;
}

/// The core's side of a spell script's context (the caster's session, or creature, implements it).
interface SpellHost
{
    uint hostSpellId();
    ActionResult hostCastFrom(EntityRef caster, uint spell, EntityRef target, bool triggered);
    ActionResult hostDamage(EntityRef target, uint amount);
    ActionResult hostEnergize(EntityRef target, ubyte power, int amount);
    uint hostHealth(EntityRef who);
    uint hostMaxHealth(EntityRef who);
    bool hostPlayerControlled(EntityRef who);
    void hostQuestEvent(EntityRef player, uint quest);
    void hostKillCredit(EntityRef player, uint entry);
    EntityRef hostSummonAt(uint entry, Location at, uint despawnMs, EntityRef attack);
    ActionResult hostSignalCreature(EntityRef to, uint id, int value);
    void hostLog(string text);
    ActionResult hostModifyThreat(EntityRef creature, EntityRef target, int percent);

    // Spell scripts of items, quests and the world:
    uint hostRandom(uint below);
    ActionResult hostAddThreat(EntityRef creature, EntityRef target, float amount);
    ActionResult hostSay(EntityRef speaker, int textEntry, EntityRef target);
    ActionResult hostPlayVisual(EntityRef who, uint kit);
    size_t hostEnemiesNear(EntityRef of, float range, EntityRef[] into);
    ActionResult hostAttack(EntityRef creature, EntityRef victim);
    bool hostInCombat(EntityRef who);
    ActionResult hostUnitFlags(EntityRef creature, uint flags, bool set);
    ActionResult hostRooted(EntityRef creature, bool on);
    ActionResult hostArmed(EntityRef creature, bool armed);
    ActionResult hostRemoveAura(EntityRef who, uint spell);
    int hostPower(EntityRef who, ubyte power);
    uint hostNativeDisplay(EntityRef who);
    ActionResult hostTransformModel(EntityRef who, uint model);
    ActionResult hostSayBroadcast(EntityRef speaker, uint text, EntityRef target);
    bool hostHasAura(EntityRef who, uint spell);
    ubyte hostRaceOf(EntityRef who);
    ubyte hostGenderOf(EntityRef who);
    ActionResult hostPlaySound(EntityRef player, uint sound);
    ActionResult hostDespawn(EntityRef creature, uint delayMs);
    // Class spells:
    ActionResult hostCastCustom(EntityRef caster, uint spell, EntityRef target, int[3] values, ubyte which);
    ActionResult hostSetPower(EntityRef who, ubyte power, int value);
    float hostDamageMultiplier(ubyte effect);
    uint hostResetCooldowns(EntityRef who, uint family, uint schoolMask, uint except);
    int hostEffectValue(ubyte effect);
    int hostAffectingAuraTotal(EntityRef who, ubyte auraType);
    int hostSpellPower(EntityRef who);
    ActionResult hostCastHighestRank(EntityRef who, uint firstRank, bool resetCooldown);
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
    private bool refused_;
    private CastRefusal refusal_;
    private bool excluded_;

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
    uint maxHealth(EntityRef who) { return host.hostMaxHealth(who); }
    bool playerControlled(EntityRef who) { return host.hostPlayerControlled(who); }

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

    // Spell scripts of items, quests and the world:

    /// A number below `below` (0 if it is 0), from the map's dice.
    uint random(uint below) { return host.hostRandom(below); }

    /// `AddThreat`: `target` is on `creature`'s threat list, by `amount` more (0: just on it).
    ActionResult addThreat(EntityRef creature, EntityRef target, float amount = 0)
    {
        return host.hostAddThreat(creature, target, amount);
    }

    /// A creature says the `script_texts` row `entry` (negative), with its sound and emote, at `target`.
    ActionResult say(EntityRef speaker, int entry, EntityRef target = EntityRef.init)
    {
        return host.hostSay(speaker, entry, target);
    }

    /// `SMSG_PLAY_SPELL_VISUAL`: visual kit `kit` (`SpellVisualKit.dbc`) on a unit, for all who see it.
    ActionResult playVisual(EntityRef who, uint kit) { return host.hostPlayVisual(who, kit); }

    /// The living creatures within `range` yards of `of` that are its enemies (critters not), as many as
    /// `into` holds.
    size_t enemiesNear(EntityRef of, float range, EntityRef[] into) { return host.hostEnemiesNear(of, range, into); }

    /// A creature attacks `victim` (`AttackStart`).
    ActionResult attack(EntityRef creature, EntityRef victim) { return host.hostAttack(creature, victim); }

    /// Whether a unit is fighting.
    bool inCombat(EntityRef who) { return host.hostInCombat(who); }

    /// Sets (or clears) a creature's `UnitFlag`s.
    ActionResult unitFlags(EntityRef creature, uint flags, bool set = true)
    {
        return host.hostUnitFlags(creature, flags, set);
    }

    /// A creature is held where it stands (`UNIT_STAT_ROOT`), or let go.
    ActionResult rooted(EntityRef creature, bool on) { return host.hostRooted(creature, on); }

    /// A creature's hands are empty (`LoadEquipment(0)`), or hold its own equipment again.
    ActionResult armed(EntityRef creature, bool armed) { return host.hostArmed(creature, armed); }

    /// A unit's aura of `spell` goes.
    ActionResult removeAura(EntityRef who, uint spell) { return host.hostRemoveAura(who, spell); }

    /// A unit's power of a kind; -1 if it has none of it (a warrior's mana) or is not here.
    int power(EntityRef who, Power kind) { return host.hostPower(who, kind); }

    /// A unit's own model (`UNIT_FIELD_NATIVEDISPLAYID`); 0 if it is not here.
    uint nativeDisplay(EntityRef who) { return host.hostNativeDisplay(who); }

    /// For the spell's transform aura on `who` (one of no creature's): it shows `model` (the Orb of Deception's).
    ActionResult transformModel(EntityRef who, uint model) { return host.hostTransformModel(who, model); }

    /// A creature says `broadcast_text` `text` (its sound and emote too), at `target`.
    ActionResult sayBroadcast(EntityRef speaker, uint text, EntityRef target = EntityRef.init)
    {
        return host.hostSayBroadcast(speaker, text, target);
    }

    /// Whether a unit here has `spell`'s aura.
    bool hasAura(EntityRef who, uint spell) { return host.hostHasAura(who, spell); }

    /// A player's race (`Races`: 1 human ... 8 troll); 0 for anything else.
    ubyte raceOf(EntityRef who) { return host.hostRaceOf(who); }

    /// A player's sex: 0 male, 1 female (`Gender`); 2 for anything else.
    ubyte genderOf(EntityRef who) { return host.hostGenderOf(who); }

    /// `SMSG_PLAY_SOUND` for a player alone (`PlayDirectSound` to it).
    ActionResult playSound(EntityRef player, uint sound) { return host.hostPlaySound(player, sound); }

    /// A creature goes after `delayMs` (`ForcedDespawn`).
    ActionResult despawn(EntityRef creature, uint delayMs = 0) { return host.hostDespawn(creature, delayMs); }

    /// For `TargetChecked`: the effect passes this target over.
    void exclude() { excluded_ = true; }

    /// Whether a handler excluded the target.
    @property bool excluded() const { return excluded_; }

    /// For `CastChecked`: the cast fails, for `reason`.
    void refuse(CastRefusal reason = CastRefusal.badTargets)
    {
        refused_ = true;
        refusal_ = reason;
    }

    /// Whether a handler refused the cast, and why.
    @property bool refused() const { return refused_; }
    /// ditto
    @property CastRefusal refusal() const { return refusal_; }

    // Class spells:

    /**
     * `CastCustomSpell`: `caster` casts `spell` at `target`, triggered, its effects' amounts the given ones (`values[i]`
     * for each effect `i` with its bit in `which`; the rest as the spell has them).
     */
    ActionResult castCustom(EntityRef caster, uint spell, EntityRef target, int[3] values, ubyte which = 1)
    {
        return host.hostCastCustom(caster, spell, target, values, which);
    }

    /// A unit's power of a kind set to `value` (`SetPower`).
    ActionResult setPower(EntityRef who, Power kind, int value) { return host.hostSetPower(who, kind, value); }

    /// The spell's `DmgMultiplier` of an effect (what each point of rage is worth to Execute).
    float damageMultiplier(ubyte effect) { return host.hostDamageMultiplier(effect); }

    /**
     * `RemoveSomeCooldown`: the player's cooldowns end on its spells of `family` (`SpellFamilyName`) that have
     * one, of a school in `schoolMask` (0: any), but `except`. How many ended.
     */
    uint resetCooldowns(EntityRef who, uint family, uint schoolMask = 0, uint except = 0)
    {
        return host.hostResetCooldowns(who, family, schoolMask, except);
    }

    /// An amount of the spell's effect `effect`, rolled at its caster's level (`CalculateSpellEffectValue`).
    int effectValue(ubyte effect) { return host.hostEffectValue(effect); }

    /**
     * The amounts summed of `who`'s auras of `auraType` (an `AuraType` number) that affect the spell (their spell
     * mask has it: Improved Life Tap's dummy).
     */
    int affectingAuraTotal(EntityRef who, ubyte auraType) { return host.hostAffectingAuraTotal(who, auraType); }

    /// `who` casts the highest rank it knows of the chain of `firstRank` at itself (its cooldown ended first, if
    /// `resetCooldown`): Vanish's Stealth.
    ActionResult castHighestRank(EntityRef who, uint firstRank, bool resetCooldown = true)
    {
        return host.hostCastHighestRank(who, firstRank, resetCooldown);
    }

    /// What `who`'s spell power adds to the spell (`SpellDamageBonusDone`, by its cast time).
    int spellPower(EntityRef who) { return host.hostSpellPower(who); }

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

/**
 * A scripted event began (`scripted_event_id`): a spell's `SEND_EVENT` or a game object's event, started by
 * `source` (the caster, the object's user) at `target`. `consume` keeps its database script from following.
 */
struct EventStarted
{
    uint event;
    EntityRef source, target;
}

/// An event script's handle: what an area trigger's script can do, around the player who started it.
struct EventContext
{
    AreaTriggerContext inner; /// what it can do (an area trigger script's abilities)
    alias inner this;

    @disable this(this);

    /// The core makes one around the player who started the event, or is its target.
    this(AreaTriggerHost host) pure nothrow @nogc @safe
    {
        inner = AreaTriggerContext(host);
    }
}

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
    // Kalimdor scripts:
    ActionResult hostSignalCreature(EntityRef to, uint id, int value);
    // Dungeon scripts:
    bool hostHasItem(EntityRef player, uint item);

    // Raid scripts:
    int hostAskDungeon(uint id);

    // Instance round 2:
    ActionResult hostTeleportPlayer(EntityRef player, Location at);
    bool hostHasAura(EntityRef who, uint spell);

    // Open-world round 2:
    bool hostLocationOf(EntityRef who, out Location at);
    uint hostHealthPercentOf(EntityRef who);
    uint hostRespawnObjectsNear(uint entry, Location at, float range, uint seconds);
    void hostFlagForPvP(EntityRef player);
    ActionResult hostAiEvent(EntityRef creature, uint type, EntityRef invoker);
    size_t hostCreaturesNear(Location at, uint entry, float range, EntityRef[] into);

    // World events:
    uint hostCompanionEntry(EntityRef player);
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
    /// The creature entry of the player's companion (a mini-pet) out, 0 if none.
    uint companionEntry(EntityRef player) { return host.hostCompanionEntry(player); }
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
    // Kalimdor scripts:

    /// A `Signal` for a creature's script (on another node: sent there).
    ActionResult signal(EntityRef to, uint id, int value = 0) { return host.hostSignalCreature(to, id, value); }

    // Raid scripts:

    /// The dungeon script's answer to question `id` (`Asked`); 0 outside a dungeon copy.
    int askDungeon(uint id) { return host.hostAskDungeon(id); }

    // Instance round 2:

    /// `player` is at `at` at once, on this map (out of C'Thun's stomach).
    ActionResult teleport(EntityRef player, Location at) { return host.hostTeleportPlayer(player, at); }

    /// Whether `who` (a player or a creature here) has `spell`'s aura.
    bool hasAura(EntityRef who, uint spell) { return host.hostHasAura(who, spell); }

    // Open-world round 2:

    /// Where a unit or object on the player's map is; false if it is not seen here.
    bool locationOf(EntityRef who, out Location at) { return host.hostLocationOf(who, at); }

    /// A unit's health in percent; uint.max if it is not here.
    uint healthPercentOf(EntityRef who) { return host.hostHealthPercentOf(who); }

    /// The game objects of `entry` within `range` yards of `at` that were taken away (used up, not there
    /// by default) come back for `seconds` (0: until their own respawn time says); how many came.
    uint respawnObjectsNear(uint entry, Location at, float range, uint seconds = 0)
    {
        return host.hostRespawnObjectsNear(entry, at, range, seconds);
    }

    /// A player is flagged for PvP (`UpdatePvP(true)`), as attacking an enemy would flag it.
    void flagForPvP(EntityRef player) { host.hostFlagForPvP(player); }

    /// A creature here (one run by its `creature_ai_scripts`) receives AI event `type` (`AIEventType`: 5 is
    /// `AI_EVENT_CUSTOM_EVENTAI_A`) from itself, `invoker` its cause (`SendAIEvent`).
    ActionResult aiEvent(EntityRef creature, uint type, EntityRef invoker) { return host.hostAiEvent(creature, type, invoker); }

    /// The living creatures of `entry` (0: any) within `range` yards of `at`, as many as `into` holds.
    size_t creaturesNear(Location at, uint entry, float range, EntityRef[] into)
    {
        return host.hostCreaturesNear(at, entry, range, into);
    }
}

// ---------------------------------------------------------------------------
// Open-world round 2: world map scripts (`@world`, bound by `world_template.ScriptName`), one per continent
// ---------------------------------------------------------------------------

/**
 * A world map script's handle on its continent (as much of it as this node simulates): what a dungeon
 * script can do in its copy. It hears the continent's creatures die, the signals of the scripts on it
 * (`signalDungeon` there), questions, and its own steps; it keeps nothing across a restart.
 */
struct WorldMapContext
{
    InstanceContext inner; /// what it can do (a dungeon script's abilities, on the continent)
    alias inner this;

    @disable this(this);

    /// The core makes one around a continent's map.
    this(InstanceHost host) pure nothrow @nogc @safe
    {
        inner = InstanceContext(host);
    }
}

// ---------------------------------------------------------------------------
// Open-world round 2: item scripts (`@item`, bound by `item_template.ScriptName`), one per item
// ---------------------------------------------------------------------------

/// A player uses item `item` (its spell about to be cast at `target`): `ItemContext.consume` makes the
/// use fail (the cast does not start, the item stays), as a script refusing it does (`pItemUse`).
struct ItemUsed
{
    EntityRef player;
    uint item;
    EntityRef target;
}

/// An item script's handle: what an area trigger's script can do, around the player using the item.
struct ItemContext
{
    AreaTriggerContext inner; /// what it can do (an area trigger script's abilities)
    alias inner this;

    @disable this(this);

    /// The core makes one around the player using the item.
    this(AreaTriggerHost host) pure nothrow @nogc @safe
    {
        inner = AreaTriggerContext(host);
    }
}

// ---------------------------------------------------------------------------
// Raid scripts: questions to a dungeon, players arriving, picking targets, flags
// ---------------------------------------------------------------------------

/// A script asks its dungeon's script question `id` (`CreatureContext.askDungeon`), which answers with
/// `InstanceContext.answer`. Asking changes nothing.
struct Asked
{
    EntityRef from;
    uint id;
}

/// A database condition of type INSTANCE_SCRIPT. The script answers with 1 when it holds.
struct InstanceCondition
{
    uint id;
}

/// A player came into the copy (entered it, logged in there, or was carried there).
struct PlayerEntered
{
    EntityRef player;
}

/// A player used a game object of the copy (before the object's own script and its usual use).
struct ObjectUsedHere
{
    EntityRef object;
    EntityRef player;
}

/// How `CreatureContext.selectTarget` picks among those it fights.
enum Pick : ubyte
{
    random,       /// any of them
    topThreat,    /// the most hated (`skip` 1: the second, ...)
    bottomThreat, /// the least hated
    nearest,
    farthest,
}

/// What a target `selectTarget` picks must be: bits, any together.
enum PickFilter : uint
{
    none = 0,
    player = 1,      /// a player (not a pet or a creature)
    notVictim = 2,   /// not its victim
    manaUser = 4,    /// with mana
    notManaUser = 8, /// without mana
    inMelee = 16,    /// within its melee reach
    notInMelee = 32, /// beyond it
}

/// Where an encounter of a dungeon stands (CMaNGOS's instance data values).
enum EncounterState : ubyte
{
    notStarted = 0,
    inProgress = 1,
    failed = 2,
    done = 3,
    special = 4,
}
