/**
 * A map with the players and objects on it, who sees whom, and the packets
 * that follow from that.
 *
 * Players are kept in square cells of `cellSize` yards (an eighth of a map tile),
 * size, so "who is near" looks at a handful of cells instead of the whole map.
 * Seeing is symmetric: two players see each other when they are within the
 * visibility distance. When that starts, each gets the other's create block;
 * when it ends, an out-of-range block; when one leaves the world, the other
 * gets `SMSG_DESTROY_OBJECT`. Visibility is recomputed when a player has
 * moved `relocationLimit` yards since the last time (the
 * `visibility_relocation_lower_limit` setting).
 *
 * The map knows players through `Inhabitant`, which `Character` implements:
 * the character, and a way to deliver a packet. Tests implement it directly.
 *
 * Creatures and game objects (`MapObject`) are kept in the same cells. A
 * cell's spawns are created when a player first comes near it
 * (`loadCell`), through the `Spawner` the map was given, and stay.
 * Players see objects within the visibility distance; the create blocks of
 * everything that came into sight are sent together.
 *
 * Objects that move on their own (`Moving`, creatures) tick with the map:
 * one that moved changes cell, and once it has moved `relocationLimit` yards
 * the players it came near get it and those it left lose it. The map is the
 * `MotionWorld` movement asks for heights and sends its packets through.
 *
 * In a cluster (docs/CLUSTER.md) a map holds only what its node owns: a cell's spawns are
 * created only if `owns` says the cell is this node's, an object belongs to the cell it spawned in
 * (its home, until objects migrate), and when a region is lost its objects go (`release`)
 * and the players who saw them get an out-of-range block. Standalone, `owns` is null: everything is.
 *
 * Replication (`dmangos.world.replication`): the map tells other nodes which cells its
 * players are near (`takeInterest`), sends replicas of its own objects in cells other nodes are
 * interested in (`peerInterest`, through `replicator`), and keeps the replicas other nodes send
 * (`replicaCreated` and the like) with its own objects, where its players see them.
 */
module dmangos.world.map;

import dmangos.vmap.math : Vector3;
import core.time : Duration, MonoTime, msecs, seconds, usecs;
import std.algorithm.searching : canFind;
import std.random : Random, unpredictableSeed;

import dmangos.events : EventQueue;
import dmangos.store : SlotBits, Store;

import dmangos.serialization : serialize;
import dmangos.bytes : ByteWriter;
public import dmangos.world.grid : cellSize;
import dmangos.world.grid : cellCoordinate, cellKey, cellKeyAt;
import dmangos.world.creatureai : LinkEvent;
import dmangos.world.creatureai : CombatWorld;
import dmangos.world.unit : UnitRef;
import dmangos.world.creature : Creature;
import dmangos.world.elevators : ElevatorPath;
import dmangos.world.gameobject : GameObject, GameObjectWorld, goStateReady;
import dmangos.world.gameobjectcollision : GameObjectCollision;
import dmangos.world.motion : MotionWorld;
import dmangos.world.movement : Position;
import dmangos.world.objects : maxUpdatePacketBytes, seenByEveryone, seenByOwner, UpdateData, UpdatePacket, UpdateValues;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ServerDestroyObject;
import dmangos.world.player : DeathState, Player;
import dmangos.world.updatefields : GAMEOBJECT_STATE, TypeId;
import dmangos.world.migration : decodeBundle, encodeBundle, Migrant, MigrantKind;
import dmangos.world.replication : decodeSlots, encodeMotion, encodePlayerState, encodeSlots, encodeState, Replica,
    Replicable, Replicator;
import dmangos.world.terrain : defaultHeightSearch, defaultWaterSearch, invalidHeightValue, LiquidData,
    LiquidStatus, Terrain;

/// What the map needs from a player in it.
interface Inhabitant
{
    /// The character being played.
    @property const(Player) character() const;

    /// Frames and queues a packet for this player's client.
    void deliver(Opcode opcode, const(ubyte)[] body_);

    /// The create block `viewer` gets when this player comes into its sight.
    UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const;

    /**
     * Which version of this player's create block `viewer` gets: viewers with the same kind get
     * the same bytes, so the map builds and compresses each version once (a stranger's view, a
     * group member's view).
     */
    uint appearanceKind(const Inhabitant viewer) const;
}

/// What visibility needs of a player (`playerSees`): a local one's, or a replica's from its fields.
struct PlayerView
{
    ulong guid;
    bool alive;   /// not dead at all
    bool ghost;   /// released: a spirit (a body not yet released is neither)
    bool gmTag;   /// `.gm on` (`PlayerFlags.gm`)
    bool gmInvisible; /// `.invisible`
    bool stealthed;   /// under Stealth or Prowl (`MOD_STEALTH`), or invisible (`MOD_INVISIBILITY`): seen only if detected
}

/// What the world knows of a viewer and a player it might see (`Map.visibilityFacts`).
struct VisibilityFacts
{
    bool sameGroup;
    bool cooperate;         /// may help each other: the same side
    float corpseDistance = float.infinity; /// from the viewer's corpse to the other, on this map
    bool detected = true;   /// the viewer detects the other's stealth (`dmangos.world.combat.detects`)
}

/// How near its corpse a ghost sees the living: CMaNGOS's 20 + 25 yards (times an aggro rate of 1).
enum float ghostSightOfTheLiving = 45;

/**
 * Whether `viewer` sees the player `seen`. A game master with its tag on sees ghosts (ArcEmu's `Player::CanSee`,
 * `bGMTagOn`); the rest is CMaNGOS's `Player::IsVisibleInGridForPlayer`: group members see each other; the
 * living (and the dead not yet released) see only those not released; a ghost sees the ghosts of its side,
 * and the living near its own corpse. `facts` is only asked when a ghost is involved.
 */
bool playerSees(PlayerView viewer, PlayerView seen, scope VisibilityFacts delegate() facts)
{
    if (seen.gmInvisible) // `.invisible` (ArcEmu's `m_isGmInvisible`): its group and tagged game masters; no ghost
    {
        if (viewer.ghost)
            return false;
        return viewer.gmTag || facts().sameGroup;
    }
    // Stealth: its group and its side see it, an enemy only when it detects it (CMaNGOS's `Unit::IsVisibleForOrDetect`
    // for players); a ghost by the ghosts' rules below.
    if (seen.stealthed && seen.guid != viewer.guid && !seen.ghost && !viewer.ghost && !viewer.gmTag)
    {
        const f = facts();
        return f.sameGroup || f.cooperate || f.detected;
    }
    if (!viewer.ghost && !seen.ghost)
        return true; // every rule below would say so
    if (viewer.gmTag)
        return true;
    const f = facts();
    if (f.sameGroup)
        return true;
    if (!viewer.ghost)
        return false; // the living do not see ghosts
    if (seen.ghost)
        return f.cooperate;
    return seen.alive && f.corpseDistance <= ghostSightOfTheLiving;
}

unittest
{
    // A stealthed player: its group and its side see it, an enemy only when it detects it.
    const hidden = PlayerView(2, true, false, false, false, true);
    const enemy = PlayerView(1, true), gm = PlayerView(3, true, false, true);
    assert(!playerSees(enemy, hidden, () => VisibilityFacts(false, false, float.infinity, false)));
    assert(playerSees(enemy, hidden, () => VisibilityFacts(false, false, float.infinity, true)));
    assert(playerSees(enemy, hidden, () => VisibilityFacts(false, true, float.infinity, false)));
    assert(playerSees(enemy, hidden, () => VisibilityFacts(true, false, float.infinity, false)));
    assert(playerSees(gm, hidden, () => VisibilityFacts(false, false, float.infinity, false)));
    assert(playerSees(hidden, hidden, () => VisibilityFacts.init));
    // A ghost of its side sees it only near its corpse, as any living player.
    const ghost = PlayerView(4, false, true);
    assert(!playerSees(ghost, hidden, () => VisibilityFacts(false, true, 100, true)));
    assert(playerSees(ghost, hidden, () => VisibilityFacts(false, true, 10, true)));
}

/// A local player's `PlayerView`.
PlayerView viewOf(const Player p)
{
    import dmangos.world.player : PlayerFlags;

    import dmangos.world.spellids : AuraType;

    return PlayerView(p.guid, p.deathState == DeathState.alive, p.deathState == DeathState.ghost,
        p.hasFlag(PlayerFlags.gm), p.gmInvisible, p.auras.hasType(AuraType.modStealth)
        || p.auras.hasType(AuraType.modInvisibility));
}

/// A player replica's `PlayerView`, from its fields.
PlayerView viewOf(ulong guid, const ref UpdateValues values)
{
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.updatefields : PLAYER_FLAGS, UNIT_FIELD_HEALTH;

    const flags = values.get!PLAYER_FLAGS;
    return PlayerView(guid, values.get!UNIT_FIELD_HEALTH > 0 && !(flags & PlayerFlags.ghost),
        (flags & PlayerFlags.ghost) != 0, (flags & PlayerFlags.gm) != 0);
}

/**
 * A map object some of whose fields each viewer sees differently (a creature's tapped and lootable
 * flags). The map sends the fields as everyone sees them, and to each
 * viewer whose differ, its own.
 */
interface PerViewer
{
    /// Whether some viewer may see some field differently now.
    bool personalized() const;

    /// The slots that may differ.
    const(size_t)[] personalSlots() const;

    /// What `viewer` (in group `viewerGroup`, 0 for none) sees in `slot` where everyone else sees `value`.
    uint fieldFor(ulong viewer, uint viewerGroup, size_t slot, uint value) const;
}

/// A `ValueAdjuster` for one viewer of a `PerViewer`.
struct ViewerAdjust
{
    const PerViewer object;
    ulong viewer;
    uint viewerGroup;

    ///
    uint adjust(size_t slot, uint value) const
    {
        return object.fieldFor(viewer, viewerGroup, slot, value);
    }
}

/// A creature or game object on a map, as players see it.
interface MapObject
{
    /// Its guid.
    @property ulong guid() const;

    /// Where it is.
    @property Position position() const;

    /// Its create block.
    UpdateData appearance(uint serverTime) const;

    /// Its update fields, to change them (`.modify`, `.npc` commands); `Map.flushObjectChanges` sends the changes.
    ref UpdateValues fields();
}

/// A map object that moves on its own: it ticks with the map.
interface Moving : MapObject
{
    /// `diff` milliseconds on.
    void tick(MotionWorld world, int diff);

    /**
     * Whether ticking it would do nothing until something wakes it (`Map.wake`): no walk under way
     * and nothing that starts one by itself. A resting object is left out of the map's tick.
     */
    @property bool resting() const;
}

/**
 * A moving object that can say how long it will have nothing to do (docs/DESIGN.md, step 4): the map
 * takes it out of the tick for that long, and its next tick is given all the time that passed.
 */
interface Idler
{
    /// Milliseconds it would only count down; 0 if it must tick every time.
    @property int idleFor() const;
}

/// Creates the spawns of one cell of a map: called once per cell, when a player first comes near.
alias Spawner = MapObject[] delegate(uint map, ulong cell);

/// The most create blocks in one update packet, so that a crowded place does not make one huge packet.
private enum maxBlocksPerPacket = 40;

/// Distances that decide who sees and hears whom (the `visibility_*` and `listen_range_*` settings).
struct MapSettings
{
    float visibilityDistance = 100; /// `visibility_distance`
    float relocationLimit = 10;     /// `visibility_relocation_lower_limit`
    uint unloadIdleMs;              /// `grid_cleanup_delay_seconds`: a cell idle for so long unloads (0: never)
}

/// Sends `packet` to `to`, serialized and framed for that client.
void deliverPacket(T)(Inhabitant to, auto ref const T packet) if (is(typeof(T.opcode) == Opcode))
{
    to.deliver(T.opcode, packetBody(packet));
}

/// The serialized body of `packet`, to deliver to several players.
const(ubyte)[] packetBody(T)(auto ref const T packet)
{
    ByteWriter body_;
    serialize(body_, packet);
    return body_.data;
}

/// Sends an update, compressed if it is large.
void deliverUpdate()(Inhabitant to, auto ref const UpdateData update)
{
    deliverBuilt(to, update.build());
}

/// Sends an update already built (and compressed), to several players alike.
void deliverBuilt(Inhabitant to, const UpdatePacket packet)
{
    to.deliver(packet.compressed ? Opcode.SMSG_COMPRESSED_UPDATE_OBJECT : Opcode.SMSG_UPDATE_OBJECT, packet.body_);
}

/// No cell (an entity not placed in one).
private enum ulong noCell = ulong.max;
/// Not in the tick.
private enum uint notTicking = uint.max;

/**
 * Everything the map keeps about one player or object (docs/DESIGN.md, "Entity identity"): in one
 * slot of `Map.entities`, found from its guid once (`Map.slotOf`), then by slot. Who sees what is kept
 * from both sides: a player's `known` (what its client has) and an entity's `viewers` (the players
 * whose clients have it), so sending to an object's viewers walks its viewers, not every player.
 */
private struct Entity
{
    ulong guid;
    Inhabitant player;          // a player simulated here; null for an object
    MapObject object;           // a creature, game object, corpse or replica; null for a player
    Moving mover;               // the object, if it moves on its own
    bool replica;               // another node simulates it
    ulong cell = noCell;        // the cell it is in
    uint cellIndex;             // its place in that cell's list
    ulong home = noCell;        // an object's own: the cell it spawned in (none for a replica)
    Position visibilityAt;      // where who sees it was last worked out
    uint tickIndex = notTicking; // its place in `Map.ticking`
    ulong lastTickAt;           // the map's clock when it last ticked (`Map.clockMs`)
    ulong noticeAt;             // a moving creature looks for players to notice again from then
    bool changed;               // its fields changed in the tick: sent at its end
    uint sleepToken;            // asleep on the timer wheel under this token; 0: not asleep
    Idler idler;                // the object, if it can say how long it will idle
    uint[] viewers;             // the players (slots) whose clients have it
    ushort[] replicatedTo;      // the peers holding a replica of it (an own object, a player here)
    ulong[] interest;           // cells a local player or fighting creature needs to observe

    // A player's own.
    bool ghost;                 // released, as of its last `updateVisibility` (which each death and life runs)
    bool farSeeing;             // it sees from `eye`, not where it stands (Far Sight, Eagle Eye, Mind Vision)
    Position eye;               // where it sees from, while `farSeeing`
    SlotBits known;             // the slots its client has: players and objects
    ulong[] lingering;          // guids its client has that this map does not hold yet
}

/// The players and objects in one cell, by slot.
private struct CellList
{
    uint[] players;
    uint[] objects;
}

/// An object asleep on the map's timer wheel until `wakeAt` (the map's clock).
private struct Sleeper
{
    uint slot;
    uint token;
    ulong wakeAt;
}

/// The timer wheel: so many buckets of so many milliseconds (25.6 seconds round; a longer sleep goes round again).
private enum size_t wheelBuckets = 256;
/// ditto
private enum ulong wheelGrain = 100;

/// A moving creature looks for players to notice at most this often (ms).
private enum ulong aiRelocationNotifyDelay = 1000;

/// An object idle for less than this stays in the tick (sleeping it would cost more than it saves).
private enum int minimumSleep = 250;

/// Removes `value` from `list` (order is not kept).
private void dropValue(T)(ref T[] list, T value)
{
    foreach (i, v; list)
        if (v == value)
        {
            list[i] = list[$ - 1];
            list.length -= 1;
            list.assumeSafeAppend();
            return;
        }
}

/// See the module documentation.
final class Map : CombatWorld, GameObjectWorld
{
    immutable uint id;

    private
    {
        MapSettings settings;
        uint delegate() serverTime;
        Store!Entity entities;          // players and objects, by slot
        uint[ulong] slotOf;             // guid -> slot: the only lookup by guid
        uint[] players;                 // the slots of the players here
        CellList[ulong] cellLists;      // cell key -> who and what is in it
        size_t replicaCount_;

        Spawner spawner;
        bool[ulong] loadedCells;        // cells whose spawns exist

        Terrain terrain;                // heights for movement; none in tests
        GameObjectCollision objectCollision;
        Random rng;
        uint[] ticking;                 // the objects in the tick (not resting), by slot
        uint[] tickCopy;                // `ticking` as a tick began
        bool ticking_;                  // in `update`: changes wait for its end
        uint[] changedSlots;            // the objects changed in the tick, in order
        ulong clockMs;                  // the map's own clock: milliseconds of ticks so far
        Sleeper[][wheelBuckets] wheel;  // objects asleep, by the bucket of their waking (docs/DESIGN.md, step 4)
        ulong wheelDone;                // the wheel's buckets are woken up to this one (`clockMs / wheelGrain`)
        uint sleepCounter;              // the last `Entity.sleepToken` given
        size_t sleeping;                // how many are asleep
        bool delegate(ulong cell) owns; // whether this node owns a cell; null: every cell

        // Replication.
        bool[ushort][ulong] peerCells;     // cell key -> peers that want what this node simulates there
        uint[ulong] localInterest;         // cell key -> local players and fighting creatures near it
        bool[ulong] interestAdded, interestRemoved; // changes since `takeInterest`

        // Players arriving from another node: see `Entity.lingering`; forgotten after `lingerFor`.
        MonoTime[ulong] lingerUntil;    // player guid -> when its lingering guids go out of range
        Duration unticked;              // time not yet given to the movers (under a millisecond)
        uint[ulong] idleMs;             // loaded cell -> how long no player (here or on a peer) has been near
        int idleCheck;                  // ms until the next look for idle cells
    }

    /// The dungeon instance this map is (0: the map itself, a continent or a shared dungeon).
    uint instanceId;

    ///
    this(uint id, MapSettings settings, uint delegate() serverTime, Spawner spawner = null, Terrain terrain = null,
        bool delegate(ulong cell) owns = null, GameObjectCollision objectCollision = null)
    in (serverTime !is null)
    {
        this.owns = owns;
        this.id = id;
        this.settings = settings;
        this.serverTime = serverTime;
        this.spawner = spawner;
        this.terrain = terrain;
        this.objectCollision = objectCollision;
        rng = Random(unpredictableSeed);
    }

    /// Sends replicas of this map's own objects to other nodes; null when standalone.
    Replicator replicator;

    package ElevatorPath delegate(ulong guid, const ref UpdateValues fields) elevatorPath;
    package uint delegate() elevatorClock;

    /// Number of creatures and game objects (replicas included) on the map.
    @property size_t objectCount() const
    {
        return entities.length - players.length;
    }

    // -----------------------------------------------------------------------
    // Slots
    // -----------------------------------------------------------------------

    /// The slot of `guid`; `uint.max` if it is not here.
    private uint slotFor(ulong guid) const
    {
        return slotOf.get(guid, uint.max);
    }

    private ref Entity at(uint slot)
    {
        return entities.at(slot);
    }

    /// A new entity in a slot of its own.
    private uint newEntity(Entity e)
    {
        e.idler = cast(Idler) e.object;
        const slot = entities.add(e).slot;
        slotOf[e.guid] = slot;
        return slot;
    }

    /// The slot of the object `object`; `uint.max` if it is not here.
    private uint objectSlot(const MapObject object) const
    {
        const slot = slotFor(object.guid);
        return slot != uint.max && entities.at(slot).object is object ? slot : uint.max;
    }

    /// `viewer`'s client has `seen` from now on; whether it did not before.
    private bool see(uint viewer, uint seen)
    {
        if (!at(viewer).known.add(seen))
            return false;
        at(seen).viewers ~= viewer;
        return true;
    }

    /// `viewer`'s client no longer has `seen`; whether it had.
    private bool unsee(uint viewer, uint seen)
    {
        if (!at(viewer).known.remove(seen))
            return false;
        dropValue(at(seen).viewers, viewer);
        return true;
    }

    /// The slots `slot`'s client has, players or objects as `wantPlayers` says (a copy: safe to change).
    private uint[] knownOf(uint slot, bool wantPlayers)
    {
        uint[] found;
        foreach (k; at(slot).known)
            if ((at(k).player !is null) == wantPlayers)
                found ~= k;
        return found;
    }

    /**
     * What `knownOf` gives, into a list borrowed from `borrowList` (the hot paths: every movement packet
     * goes through one), so that no array is grown for it. A copy, as `knownOf`'s, because what the
     * loop over it does may change what `slot` knows.
     */
    private void knownInto(uint slot, bool wantPlayers, ref uint[] into)
    {
        foreach (k; at(slot).known)
            if ((at(k).player !is null) == wantPlayers)
                into ~= k;
    }

    // Lists of slots for the hot paths, lent out and given back last first (`scope (exit)`), so that one
    // in use is never lent again and their memory is kept from call to call.
    private uint[][] spareLists;
    private size_t listsLent;
    // What `updateVisibility` sees, kept between calls for their memory (empty outside it).
    private SlotBits playersInSight, objectsInSight;
    private int stealthCheck = 1000; // milliseconds until stealthed players' visibility is worked out again
    private uint ghosts; // players here released (`Entity.ghost`): with none, who sees whom is symmetric
    private bool updatingVisibility;

    private uint[] borrowList()
    {
        if (listsLent == spareLists.length)
            spareLists ~= null;
        auto list = spareLists[listsLent++];
        list.length = 0;
        list.assumeSafeAppend();
        return list;
    }

    private void giveBackList(uint[] list)
    in (listsLent > 0)
    {
        spareLists[--listsLent] = list;
    }

    /// Puts `slot` in cell `key`'s list.
    private void putInCell(uint slot, ulong key)
    {
        auto e = &at(slot);
        auto list = &cellLists.require(key);
        if (e.player !is null)
        {
            e.cellIndex = cast(uint) list.players.length;
            list.players ~= slot;
        }
        else
        {
            e.cellIndex = cast(uint) list.objects.length;
            list.objects ~= slot;
        }
        e.cell = key;
        updateObjectCollision(slot);
    }

    /// Takes `slot` out of its cell's list.
    private void takeFromCell(uint slot)
    {
        auto e = &at(slot);
        if (e.cell == noCell)
            return;
        if (objectCollision !is null && e.object !is null && e.object.fields.type == TypeId.gameObject)
            objectCollision.remove(slot);
        auto list = e.cell in cellLists;
        auto members = e.player !is null ? &list.players : &list.objects;
        const i = e.cellIndex, last = (*members)[$ - 1];
        (*members)[i] = last;
        at(last).cellIndex = i;
        (*members).length -= 1;
        (*members).assumeSafeAppend();
        if (list.players.length == 0 && list.objects.length == 0)
            cellLists.remove(e.cell);
        e.cell = noCell;
    }

    /// The entity in `slot` goes: nobody's client has it any more, and it has nothing.
    private void dropEntity(uint slot)
    {
        clearInterest(slot);
        foreach (v; at(slot).viewers.dup)
            unsee(v, slot);
        foreach (k; knownOf(slot, true) ~ knownOf(slot, false))
            unsee(slot, k);
        takeFromCell(slot);
        stopTicking(slot);
        if (at(slot).sleepToken)
            --sleeping;
        if (at(slot).replica)
            --replicaCount_;
        if (at(slot).player !is null)
            dropValue(players, slot);
        slotOf.remove(at(slot).guid);
        entities.remove(entities.refOf(slot));
    }

    // -----------------------------------------------------------------------
    // Objects
    // -----------------------------------------------------------------------

    /// The creature or game object with this guid, if its cell is loaded; null otherwise.
    MapObject findObject(ulong guid)
    {
        const slot = slotFor(guid);
        return slot == uint.max ? null : at(slot).object;
    }

    /// Sends what changed in an object's fields to the players whose clients have it, then forgets the changes.
    void flushObjectChanges(MapObject object)
    {
        if (objectCollision !is null && object.fields.type == TypeId.gameObject)
            updateObjectCollision(objectSlot(object));
        // In the map's tick, the change waits for the tick's end: several
        // changes of one object in a tick go out as one update.
        if (ticking_)
        {
            const slot = objectSlot(object);
            if (slot != uint.max)
            {
                if (!at(slot).changed)
                {
                    at(slot).changed = true;
                    changedSlots ~= slot;
                }
                return;
            }
        }
        sendObjectChanges(object);
    }

    /// The objects changed in the tick, at its end: one update each.
    private void sendChangedObjects()
    {
        for (size_t i = 0; i < changedSlots.length; ++i) // a send may change another: it is sent too
        {
            const slot = changedSlots[i];
            if (!entities.holds(slot) || !at(slot).changed)
                continue;
            at(slot).changed = false;
            sendObjectChanges(at(slot).object);
        }
        changedSlots.length = 0;
        changedSlots.assumeSafeAppend();
    }

    /// See `flushObjectChanges`: what changed goes to the viewers now.
    private void sendObjectChanges(MapObject object)
    {
        const slot = objectSlot(object);
        if (replicator !is null && slot != uint.max && !at(slot).replica && at(slot).replicatedTo.length)
        {
            const slots = object.fields.changedPublicSlots;
            if (slots.length)
            {
                const bytes = encodeSlots(slots);
                foreach (peer; at(slot).replicatedTo)
                    replicator.values(peer, id, object.guid, bytes);
            }
        }
        // A pet's owner also sees its owner-only fields (its experience, training points).
        const creature = cast(Creature) object;
        const owner = creature is null ? 0 : creature.petOwner;
        enum ownerMask = seenByEveryone | seenByOwner;
        const forAll = object.fields.hasChangesFor(seenByEveryone);
        if (slot != uint.max && (forAll || (owner && object.fields.hasChangesFor(ownerMask))))
        {
            auto personal = cast(PerViewer) object;
            UpdateData update;
            update.addValues(object.guid, object.fields, seenByEveryone);
            // Built (and compressed, if large) once, for every viewer who sees what everyone sees.
            UpdatePacket common;
            bool commonBuilt;
            foreach (v; at(slot).viewers)
            {
                auto who = at(v).player;
                const guid = who.character.guid;
                if (guid == owner)
                {
                    UpdateData own;
                    own.addValues(object.guid, object.fields, ownerMask);
                    deliverUpdate(who, own);
                }
                else if (!forAll)
                    continue;
                else if (personal !is null && personal.personalized)
                {
                    auto view = ViewerAdjust(personal, guid, groupOf is null ? 0 : groupOf(guid));
                    UpdateData own;
                    own.addValues(object.guid, object.fields, seenByEveryone, &view.adjust);
                    deliverUpdate(who, own);
                }
                else
                {
                    if (!commonBuilt)
                    {
                        common = update.build();
                        commonBuilt = true;
                    }
                    deliverBuilt(who, common);
                }
            }
        }
        object.fields.clearChanges();
    }

    /// The group a player is in (0: none), for what a `PerViewer` shows it; null: nobody is.
    uint delegate(ulong player) groupOf;

    /**
     * What each viewer sees of a `PerViewer`'s personal fields is sent again: who may loot a corpse
     * changed, without a field of it changing.
     */
    void refreshViewers(MapObject object)
    {
        if (cast(PerViewer) object is null)
            return;
        const slot = objectSlot(object);
        if (slot == uint.max)
            return;
        foreach (v; at(slot).viewers)
            personalize(at(v).player, object, true);
    }

    /// A corpse's personalized loot rights changed without any change to its public fields.
    void refreshReplicaLootView(Creature corpse)
    {
        import dmangos.world.replication : encodeLootView;

        const slot = objectSlot(corpse);
        if (replicator is null || slot == uint.max || !at(slot).replicatedTo.length)
            return;
        const view = encodeLootView(corpse);
        foreach (peer; at(slot).replicatedTo)
            replicator.values(peer, id, corpse.guid, view);
    }

    /// After `object`'s create block: `who`'s own view of its personal fields, if it differs (or `always`).
    private void personalize(Inhabitant who, MapObject object, bool always = false)
    {
        auto personal = cast(PerViewer) object;
        if (personal is null || (!always && !personal.personalized))
            return;
        const viewer = who.character.guid;
        auto view = ViewerAdjust(personal, viewer, groupOf is null ? 0 : groupOf(viewer));
        bool differs = always;
        foreach (slot; personal.personalSlots)
            if (view.adjust(slot, object.fields[slot]) != object.fields[slot])
                differs = true;
        if (!differs)
            return;
        UpdateData own;
        own.addSlots(object.guid, object.fields, personal.personalSlots, &view.adjust);
        deliverUpdate(who, own);
    }

    /**
     * A local player's fields changed (the session's `flushPlayerChanges`, before it forgets them):
     * the nodes holding a replica of it get what a stranger sees of the change.
     */
    void playerChanged(Inhabitant who)
    {
        const slot = slotFor(who.character.guid);
        if (slot == uint.max || at(slot).replicatedTo.length == 0)
            return;
        const slots = who.character.changedStrangerSlots;
        if (slots.length == 0)
            return;
        const bytes = encodeSlots(slots);
        foreach (peer; at(slot).replicatedTo)
            replicator.values(peer, id, who.character.guid, bytes);
    }

    /**
     * What one viewer sees of a `PerViewer`'s personal fields is sent to it again, if its client has the object:
     * its quests changed, and with them which quest objects sparkle for it (CMaNGOS `UpdateForQuestWorldObjects`).
     */
    void refreshViewer(ulong viewer, MapObject object)
    {
        if (cast(PerViewer) object is null || !seesObject(viewer, object.guid))
            return;
        personalize(at(slotFor(viewer)).player, object, true);
    }

    /// Whether the player's client has the object.
    bool seesObject(ulong player, ulong object) const
    {
        const p = slotFor(player), o = slotFor(object);
        return p != uint.max && o != uint.max && entities.at(p).player !is null && entities.at(o).player is null
            && entities.at(p).known[o];
    }

    /**
     * The slots of the objects within `range` yards of `center`. Only a player's sight loads cells
     * (`load`, `loadCell`); every other search looks at what is loaded only:
     * a creature looking for help, or a script for its buddy a thousand yards
     * off, loads nothing. A search wider than the cells that hold anything goes through those.
     */
    private uint[] objectSlotsNear(Position center, float range, bool load = false)
    {
        uint[] found;
        objectSlotsInto(center, range, found, load);
        return found;
    }

    /// What `objectSlotsNear` gives, appended to `found` (a list from `borrowList`).
    private void objectSlotsInto(Position center, float range, ref uint[] found, bool load = false)
    {
        void look(ulong key, ref const CellList list)
        {
            foreach (slot; list.objects)
                if (distanceSquared(center, entities.at(slot).object.position) <= range ^^ 2)
                    found ~= slot;
        }
        const reach = cast(long)(range / cellSize) + 1;
        if (!load && (2 * reach + 1) ^^ 2 > cellLists.length)
        {
            const cx = cellCoordinate(center.x), cy = cellCoordinate(center.y);
            foreach (key, ref list; cellLists)
            {
                const x = cast(int)(key >> 32), y = cast(int)(key & 0xFFFF_FFFF);
                if (x >= cx - reach && x <= cx + reach && y >= cy - reach && y <= cy + reach)
                    look(key, list);
            }
            return;
        }
        foreach (key; cellKeysNear(center, range))
        {
            if (load)
                loadCell(key);
            if (const list = key in cellLists)
                look(key, *list);
        }
    }

    /// The creatures and game objects within `range` yards of `center` (in loaded cells).
    MapObject[] objectsNear(Position center, float range)
    {
        MapObject[] found;
        foreach (slot; objectSlotsNear(center, range))
            found ~= at(slot).object;
        return found;
    }

    /// Loads one cell: its spawns, once.
    package void loadCell(ulong key)
    {
        if (spawner is null || key in loadedCells || (owns !is null && !owns(key)))
            return;
        loadedCells[key] = true;
        foreach (object; spawner(id, key))
        {
            const slot = slotFor(object.guid);
            if (slot == uint.max || at(slot).replica)
                hold(object, key);
        }
    }

    /// How often `update` looks for idle cells.
    enum int idleCheckInterval = 10_000;

    /**
     * Unloading idle cells (`grid_cleanup_delay_seconds`): a loaded cell no player is near, here or on a peer that
     * wants replicas of it, for `unloadIdleMs` unloads after `elapsedMs` more: its creatures and game
     * objects go (the dead keep their saved respawn time; the living come back fresh when it loads
     * again). A cell keeps its objects while one of them is fighting or away in a busy cell, or while
     * it holds something that cannot simply go (a player's corpse). Returns the cells unloaded.
     */
    size_t unloadIdleCells(uint elapsedMs)
    {
        size_t count;
        bool[ulong] due;
        foreach (cell, _; loadedCells)
        {
            if (cell in localInterest || cell in peerCells)
            {
                idleMs.remove(cell);
                continue;
            }
            auto idle = &idleMs.require(cell, 0);
            *idle += elapsedMs;
            if (*idle >= settings.unloadIdleMs)
                due[cell] = true;
        }
        if (due.length == 0)
            return 0;
        // The objects homed in each due cell; a cell that must keep them is struck off.
        ulong[][ulong] homed;
        foreach (slot, ref e; entities)
        {
            if (e.home == noCell || e.home !in due)
                continue;
            auto creature = cast(Creature) e.object;
            if (creature is null && cast(GameObject) e.object is null)
            {
                due.remove(e.home); // a corpse
                continue;
            }
            if (creature !is null && ((creature.ai !is null && (creature.ai.inCombat || creature.ai.evading))
                || e.cell in localInterest || e.cell in peerCells))
            {
                due.remove(e.home);
                continue;
            }
            homed[e.home] ~= e.guid;
        }
        foreach (cell, _; due)
        {
            if (auto gone = cell in homed)
                forget(*gone);
            loadedCells.remove(cell);
            idleMs.remove(cell);
            ++count;
        }
        return count;
    }

    /**
     * Takes in an object whose home is cell `key`. A replica of it here is replaced by it in its
     * slot (this node owns it now): its viewers keep seeing it.
     */
    private void hold(MapObject object, ulong key)
    {
        const position = object.position;
        const cell = cellKeyAt(position.x, position.y);
        auto slot = slotFor(object.guid);
        if (slot != uint.max && at(slot).replica)
            becomeOwn(slot, object, key, cell);
        else
            slot = newEntity(Entity(object.guid, null, object, cast(Moving) object, false, noCell, 0, key,
                position));
        putInCellIfOut(slot, cell);
        if (at(slot).mover !is null)
            startTicking(slot);
        replicate(slot, cell);
        if (onObjectArrived !is null)
            onObjectArrived(object);
    }

    /// A replica's slot holds the real object from now on, homed in `home` and in cell `cell`.
    private void becomeOwn(uint slot, MapObject object, ulong home, ulong cell)
    {
        auto e = &at(slot);
        e.object = object;
        e.mover = cast(Moving) object;
        e.idler = cast(Idler) object;
        e.replica = false;
        --replicaCount_;
        e.home = home;
        e.visibilityAt = object.position;
        e.replicatedTo = null;
        if (e.cell != cell)
        {
            takeFromCell(slot);
            putInCell(slot, cell);
        }
        else
            updateObjectCollision(slot);
        if (e.mover is null)
            stopTicking(slot);
    }

    private void putInCellIfOut(uint slot, ulong key)
    {
        if (at(slot).cell == noCell)
            putInCell(slot, key);
    }

    /**
     * Puts an object on the map that no cell spawned (a corpse, a creature respawned), and shows it to
     * the players who see where it is.
     */
    void addObject(MapObject object)
    {
        const go = cast(GameObject) object;
        const home = go is null ? object.position : go.stationaryPosition;
        const key = cellKeyAt(home.x, home.y);
        loadCell(key);
        const existing = slotFor(object.guid);
        if (existing != uint.max && !at(existing).replica)
            return;
        hold(object, key);
        updateObjectVisibility(object);
    }

    /// Whether the cell's spawns are here (loaded, and owned).
    bool cellLoaded(ulong key) const
    {
        return (key in loadedCells) !is null;
    }

    /// What `who` sees is worked out again (it died, or came back to life: spirit healers come or go).
    void refreshVisibility(Inhabitant who)
    {
        const slot = slotFor(who.character.guid);
        if (slot != uint.max && at(slot).player !is null)
            updateVisibility(who);
    }

    /// Takes an object off the map (a corpse gone, a creature despawned); those who saw it are told.
    void removeObject(ulong guid)
    {
        const slot = slotFor(guid);
        if (slot != uint.max && at(slot).object !is null)
            forget([guid]);
    }

    /**
     * Whether `who` can see `object` (in `slot`) at all, wherever they are: a spirit healer only shows itself to
     * the dead (by its NPC flags), and another node's player follows `playerSees`. `replica` is the map's flag
     * for the slot, so that the creature's test is the only cast an object of this node costs (this runs for
     * every object near a player who moves).
     */
    private bool objectVisibleTo(uint slot, const MapObject object, const Inhabitant who, bool replica) const
    {
        enum uint spiritHealer = 0x20, spiritGuide = 0x40; // UNIT_NPC_FLAG_SPIRITHEALER, _SPIRITGUIDE
        if (replica)
        {
            // Another node's player: as a player here would be seen.
            auto copy = cast(const Replica) object;
            if (copy !is null && copy.fieldsOf.type == TypeId.player)
                return playerSees(viewOf(who.character), viewOf(copy.guid, copy.fieldsOf),
                    () => factsOf(who.character.guid, copy.guid, copy.position));
            return true;
        }
        if (auto creature = cast(const Creature) object)
        {
            if ((creature.template_.npcFlags & (spiritHealer | spiritGuide)) && who.character.deathState == DeathState.alive)
                return false;
            // An invisible creature (a ghost of a quest, an unseen spirit): only to who sees through it, or a game master.
            import dmangos.world.spellids : AuraType;

            if (creature.auras.hasType(AuraType.modInvisibility)
                    && !who.character.hasFlag(imported!"dmangos.world.player".PlayerFlags.gm))
                return who.character.auras.seesThroughInvisibility(creature.auras);
            return true;
        }
        return true;
    }

    /// The world's facts for `playerSees` (none without `visibilityFacts`: a test's map).
    private VisibilityFacts factsOf(ulong viewer, ulong seen, Position seenAt) const
    {
        return visibilityFacts is null ? VisibilityFacts.init : visibilityFacts(viewer, seen, seenAt);
    }

    /// Whether the player in `viewer` sees the one in `seen`, both on this map.
    private bool playerSeesSlot(uint viewer, uint seen)
    {
        if (!at(viewer).ghost && !at(seen).ghost)
            return true; // the common case, from the map's own memory (`playerSees` would say so too)
        const a = at(viewer).player.character, b = at(seen).player.character;
        return playerSees(viewOf(a), viewOf(b), () => factsOf(a.guid, b.guid, b.position));
    }

    /// What the world knows of two players, for visibility; set by the world (`WorldContext`).
    VisibilityFacts delegate(ulong viewer, ulong seen, Position seenAt) visibilityFacts;

    /// One tick of the world update: every object that moves on its own, then where it got to.
    void update(Duration elapsed)
    {
        unticked += elapsed;
        const diff = cast(int) unticked.total!"msecs";
        if (diff <= 0)
            return;
        unticked -= diff.msecs;
        if (settings.unloadIdleMs && (idleCheck -= diff) <= 0)
        {
            const step = idleCheckInterval - idleCheck;
            idleCheck = idleCheckInterval;
            unloadIdleCells(step);
        }
        clockMs += diff;
        // A stealthed player is seen or lost as enemies come near it, turn and step away: who sees it is worked
        // out again once a second (stealth's detection range is a few yards, not the 10 a relocation waits for).
        // So is what a far-seeing player sees (its eye may move, and what comes near the eye is not told it).
        if (ghosts && (stealthCheck -= diff) <= 0)
        {
            import dmangos.world.spellids : AuraType;
            import dmangos.world.updatefields : PLAYER_FARSIGHT;

            stealthCheck = 1000;
            foreach (who; playersNow())
                if (who.character.auras.hasType(AuraType.modStealth) || at(slotFor(who.character.guid)).farSeeing
                        || who.character.values.get!PLAYER_FARSIGHT)
                    updateVisibility(who);
        }
        ticking_ = true;
        scope (exit)
        {
            ticking_ = false;
            sendChangedObjects();
        }
        wakeSleepers();
        // What ticks is fixed when the tick starts (a copy, into memory kept from tick to tick); an
        // object gone or put to sleep during it is not ticked after.
        tickCopy.length = ticking.length;
        tickCopy.assumeSafeAppend();
        tickCopy[] = ticking[];
        auto due = tickCopy;
        uint[] restingNow;
        Sleeper[] sleepingNow;
        foreach (slot; due)
        {
            if (!entities.holds(slot) || at(slot).tickIndex == notTicking)
                continue;
            auto mover = at(slot).mover;
            const before = mover.position;
            // All the time since its last tick: one tick's, or the whole of a sleep.
            const elapsedMs = cast(int)(clockMs - at(slot).lastTickAt);
            at(slot).lastTickAt = clockMs;
            mover.tick(this, elapsedMs);
            if (!entities.holds(slot) || at(slot).mover !is mover)
                continue; // gone while it ticked
            if (mover.position != before)
                // Moving and Replicable can provide separate MapObject references to the same entity.
                objectRelocated(at(slot).object);
            if (!entities.holds(slot) || at(slot).mover !is mover)
                continue;
            if (mover.resting)
                restingNow ~= slot;
            else if (auto idler = at(slot).idler)
            {
                const idle = idler.idleFor;
                if (idle >= minimumSleep)
                    sleepingNow ~= Sleeper(slot, 0, idle == int.max ? ulong.max : clockMs + idle);
            }
        }
        // Asked again: one woken later in the tick (by another's update) keeps ticking.
        foreach (slot; restingNow)
            if (entities.holds(slot) && at(slot).mover !is null && at(slot).mover.resting)
                stopTicking(slot);
        foreach (s; sleepingNow)
            if (entities.holds(s.slot) && at(s.slot).tickIndex != notTicking)
                if (auto idler = at(s.slot).idler)
                    if (idler.idleFor >= minimumSleep)
                        sleep(s.slot, s.wakeAt);
        expireLingering();
    }

    // -----------------------------------------------------------------------
    // Players moving between nodes
    // -----------------------------------------------------------------------

    /// How long a guid an arriving player's client has may wait for this map to hold it.
    enum Duration lingerFor = 5.seconds;

    /// Every guid the player's client has from this map: objects and players.
    ulong[] knownTo(ulong guid)
    {
        ulong[] known;
        const slot = slotFor(guid);
        if (slot == uint.max || at(slot).player is null)
            return known;
        foreach (k; at(slot).known)
            known ~= at(k).guid;
        return known;
    }

    /**
     * A player's simulation leaves for node `next`. Its replica takes the same slot while the cell is
     * observed for combat or a client still sees it. An update from the next owner replaces the replica.
     */
    void removeForMigration(Inhabitant who, ushort next)
    {
        const guid = who.character.guid;
        const slot = slotFor(guid);
        auto placeholder = new Replica(guid, next, encodePlayerState(who.character, serverTime()));
        foreach (k; knownOf(slot, true) ~ knownOf(slot, false))
            unsee(slot, k);
        clearInterest(slot);
        at(slot).replicatedTo = null; // the next node's replica replaces those elsewhere
        at(slot).lingering = null;
        lingerUntil.remove(guid);
        if (at(slot).viewers.length == 0 && (replicator is null || at(slot).cell !in localInterest))
            return dropEntity(slot);
        takeFromCell(slot);
        dropValue(players, slot);
        auto e = &at(slot);
        e.player = null;
        e.object = placeholder;
        e.mover = placeholder;
        e.replica = true;
        ++replicaCount_;
        e.known = SlotBits.init;
        e.visibilityAt = placeholder.position;
        putInCell(slot, cellKeyAt(placeholder.position.x, placeholder.position.y));
    }

    /**
     * A player's simulation arrives from another node; its client already has `known`. Nothing it has
     * is sent again: what is in sight and known is marked seen, what is in sight and new is created,
     * what it has but is out of sight goes out of range, and what it has that this map does not hold
     * yet lingers until its replica comes (adopted silently) or `lingerFor` passes (out of range).
     * Players here who saw its replica go on seeing it, now as itself.
     */
    void addMigrated(Inhabitant who, const(ulong)[] known)
    {
        const guid = who.character.guid;
        bool[ulong] knows;
        foreach (k; known)
            knows[k] = true;

        // Its replica here, if any, becomes the player in its slot: those who saw it see the real one now.
        bool[uint] sawReplica;
        auto slot = slotFor(guid);
        if (slot != uint.max && at(slot).replica)
        {
            foreach (v; at(slot).viewers)
                sawReplica[v] = true;
            takeFromCell(slot);
            stopTicking(slot);
            auto e = &at(slot);
            e.object = null;
            e.mover = null;
            e.replica = false;
            --replicaCount_;
            e.player = who;
        }
        else
            slot = newEntity(Entity(guid, who));
        players ~= slot;
        place(slot, who.character.position);
        at(slot).visibilityAt = who.character.position;
        updateInterest(slot, who.character.position); // for peers, and for unloading idle cells
        const time = serverTime();

        // Players in sight: each pair gets what it does not have.
        bool[uint] inSight;
        UpdateData received;
        MapObject[] personalAfter; // shown with a view of their own, after their create blocks
        foreach (o; playerSlotsNear(who.character.position, settings.visibilityDistance))
        {
            if (o == slot)
                continue;
            auto other = at(o).player;
            inSight[o] = true;
            see(slot, o);
            see(o, slot);
            if (other.character.guid !in knows)
                received.append(other.appearanceFor(who, time));
            if (o !in sawReplica)
                deliverUpdate(other, who.appearanceFor(other, time));
        }
        foreach (o, _; sawReplica)
            if (o !in inSight)
            {
                unsee(o, slot);
                UpdateData forget;
                forget.addOutOfRange([guid]);
                deliverUpdate(at(o).player, forget);
            }

        // Objects in sight.
        foreach (o; objectSlotsNear(who.character.position, settings.visibilityDistance, true))
        {
            auto object = at(o).object;
            if (!objectVisibleTo(o, object, who, at(o).replica))
                continue;
            inSight[o] = true;
            see(slot, o);
            if (object.guid !in knows)
            {
                if (!received.empty && received.byteSize + object.appearance(time).byteSize > maxUpdatePacketBytes)
                {
                    deliverUpdate(who, received);
                    received = UpdateData.init;
                }
                received.append(object.appearance(time));
                personalAfter ~= object;
            }
        }
        if (!received.empty)
            deliverUpdate(who, received);
        foreach (object; personalAfter)
            personalize(who, object);

        // What the client has that is not in sight: out of range if this map holds it, lingering if not.
        ulong[] gone;
        foreach (k; known)
        {
            if (k == guid)
                continue;
            const s = slotFor(k);
            if (s != uint.max && s in inSight)
                continue;
            if (s != uint.max)
                gone ~= k;
            else
                at(slot).lingering ~= k;
        }
        if (gone.length)
        {
            UpdateData forget;
            forget.addOutOfRange(gone);
            deliverUpdate(who, forget);
        }
        if (at(slot).lingering.length)
            lingerUntil[guid] = MonoTime.currTime + lingerFor;
        replicatePlayer(who);
    }

    /// Whether `object` lingered for the player in `slot` (its client has it): now it is simply seen.
    private bool adoptLingering(uint slot, ulong object)
    {
        auto lingering = &at(slot).lingering;
        foreach (g; *lingering)
            if (g == object)
            {
                dropValue(*lingering, object);
                return true;
            }
        return false;
    }

    /// Lingering guids whose replica did not come in time go out of range on the client.
    private void expireLingering()
    {
        if (lingerUntil.length == 0)
            return;
        const now = MonoTime.currTime;
        ulong[] done;
        foreach (player, until; lingerUntil)
            if (now >= until)
            {
                done ~= player;
                const slot = slotFor(player);
                if (slot != uint.max && at(slot).player !is null && at(slot).lingering.length)
                {
                    UpdateData forget;
                    forget.addOutOfRange(at(slot).lingering);
                    deliverUpdate(at(slot).player, forget);
                    at(slot).lingering = null;
                }
            }
        foreach (player; done)
            lingerUntil.remove(player);
    }

    /// Puts a resting object back in the tick: something gave it something to do.
    void wake(ulong guid)
    {
        const slot = slotFor(guid);
        if (slot != uint.max && at(slot).mover !is null)
            startTicking(slot);
    }

    /**
     * What each cell holds, weighed for how much of the loop it takes: an object in the tick
     * `ticking`, a resting one `resting`, a player simulated here `player`. Replicas count for nothing
     * here: the node that simulates them weighs them.
     */
    void weighCells(uint ticking, uint resting, uint player, scope void delegate(ulong cell, ulong weight) sink)
    {
        ulong[ulong] weights;
        foreach (slot, ref e; entities)
        {
            if (e.replica || e.cell == noCell)
                continue;
            const weight = e.player !is null ? player : e.tickIndex != notTicking ? ticking : resting;
            weights[e.cell] = weights.get(e.cell, 0) + weight;
        }
        foreach (cell, weight; weights)
            sink(cell, weight);
    }

    /// Objects in the tick now (neither resting nor asleep).
    @property size_t tickingCount() const
    {
        return ticking.length;
    }

    /// Objects asleep on the timer wheel now.
    @property size_t sleepingCount() const
    {
        return sleeping;
    }

    /// An object moved; its cell follows, and who sees it once it has gone far enough.
    void objectRelocated(MapObject object)
    {
        const slot = objectSlot(object);
        if (slot == uint.max)
            return;
        const position = object.position;
        // A creature notices and is noticed at most once a second.
        if (auto creature = cast(Creature) object)
            if (clockMs >= at(slot).noticeAt)
            {
                at(slot).noticeAt = clockMs + aiRelocationNotifyDelay;
                creatureNoticing(creature, slot);
            }
        const key = cellKeyAt(position.x, position.y);
        if (at(slot).mover !is null && at(slot).cell != key)
        {
            takeFromCell(slot);
            putInCell(slot, key);
            replicate(slot, key);
            if (at(slot).interest.length)
                updateInterest(slot, position);
        }
        else if (objectCollision !is null && object.fields.type == TypeId.gameObject)
            updateObjectCollision(slot);
        if (distanceSquared(at(slot).visibilityAt, position) < settings.relocationLimit ^^ 2)
            return;
        at(slot).visibilityAt = position;
        updateObjectVisibility(object);
    }

    /**
     * A region was lost (`inside` says which cells): the objects that spawned there go, the players
     * who saw them are told they are out of range, and the cells may load again if regained.
     */
    void release(scope bool delegate(ulong cell) inside)
    {
        ulong[] gone;
        foreach (slot, ref e; entities)
            if (e.home != noCell && inside(e.home))
                gone ~= e.guid;
        forget(gone);
        ulong[] unloaded;
        foreach (cell, _; loadedCells)
            if (inside(cell))
                unloaded ~= cell;
        foreach (cell; unloaded)
            loadedCells.remove(cell);
    }

    /**
     * A region leaves for node `next` with its objects (`inside` says which cells are it):
     * each object homed there is written out by `save`, and stays here as a replica of `next`'s object,
     * so nobody who sees it notices; peers holding replicas of it will get `next`'s. Returns the bundle
     * (`dmangos.world.migration`) for `next`.
     */
    const(ubyte)[] migrateOut(scope bool delegate(ulong cell) inside, ushort next,
        scope Migrant delegate(MapObject) save)
    {
        uint[] leaving;
        foreach (slot, ref e; entities)
            if (e.home != noCell && inside(e.home))
                leaving ~= slot;
        Migrant[] migrants;
        foreach (slot; leaving)
        {
            if (!entities.holds(slot))
                continue;
            auto migrant = moveObjectOut(slot, next, save);
            if (migrant.kind != MigrantKind.none)
                migrants ~= migrant;
        }
        ulong[] cells;
        foreach (cell, _; loadedCells)
            if (inside(cell))
                cells ~= cell;
        foreach (cell; cells)
            loadedCells.remove(cell);
        return encodeBundle(cells, migrants);
    }

    /// Captures one object and replaces its local simulation with a replica of the new owner.
    private Migrant moveObjectOut(uint slot, ushort next, scope Migrant delegate(MapObject) save)
    {
        auto object = at(slot).object;
        const home = at(slot).home;
        auto migrant = save(object);
        if (migrant.kind == MigrantKind.none)
            return migrant; // a player's corpse or pet stays here
        if (onObjectGone !is null)
            onObjectGone(object); // its state is in the migrant: what it held here goes
        migrant.home = home;
        clearInterest(slot);
        at(slot).home = noCell;
        at(slot).replicatedTo = null;
        if (auto source = cast(Replicable) object)
        {
            auto replica = makeReplica(object.guid, next, encodeState(source, serverTime()));
            auto e = &at(slot);
            e.object = replica;
            e.mover = replica;
            e.replica = true;
            ++replicaCount_;
            e.visibilityAt = replica.position;
            const cell = cellKeyAt(replica.position.x, replica.position.y);
            if (e.cell != cell)
            {
                takeFromCell(slot);
                putInCell(slot, cell);
            }
            startTicking(slot);
        }
        return migrant;
    }

    /**
     * A region arrives with its objects from its last owner: `restore` rebuilds each, which
     * replaces any replica of it in its slot (its viewers keep seeing it), and the cells it had loaded
     * count as loaded here.
     */
    void migrateIn(const(ubyte)[] bundle, scope MapObject delegate(const ref Migrant) restore)
    {
        ulong[] cells;
        Migrant[] migrants;
        decodeBundle(bundle, cells, migrants);
        foreach (cell; cells)
            loadedCells[cell] = true;
        foreach (ref m; migrants)
            moveObjectIn(m, restore);
    }

    /// Restores one object, retaining the slot and viewers of any existing replica.
    private void moveObjectIn(const ref Migrant m, scope MapObject delegate(const ref Migrant) restore)
    {
        auto object = restore(m);
        if (object is null)
            return;
        const guid = object.guid;
        const at_ = cellKeyAt(object.position.x, object.position.y);
        auto slot = slotFor(guid);
        if (slot != uint.max && at(slot).replica)
            becomeOwn(slot, object, m.home, at_);
        else
        {
            if (slot != uint.max)
            {
                // Spawned afresh here a moment ago (a gained cell loaded before its bundle was applied): the
                // migrant is the newer state. Its viewers see it go and come back as it really is.
                import dmangos.log : warning;

                warning!"migration: object %016X was spawned here afresh; the migrated one replaces it"(guid);
                forget([guid]);
            }
            slot = newEntity(Entity(guid, null, object, cast(Moving) object, false, noCell, 0, m.home,
                object.position));
            putInCell(slot, at_);
        }
        if (at(slot).mover !is null)
            startTicking(slot);
        if (auto creature = cast(Creature) object)
            if (creature.ai !is null && creature.ai.inCombat)
                trackCreatureCombat(creature, true);
        replicate(slot, at_);
        updateObjectVisibility(object);
    }

    /// A creature lease moves one spawn independently of the region containing its home.
    ubyte[] releaseCreatureLoan(ulong guid, ushort next, scope Migrant delegate(MapObject) save)
    {
        const slot = slotFor(guid);
        if (slot == uint.max || at(slot).replica)
            return null;
        auto migrant = moveObjectOut(slot, next, save);
        if (migrant.kind == MigrantKind.none)
            return null;
        if (!next)
            forget([guid]);
        return cast(ubyte[]) encodeBundle(null, [migrant]);
    }

    void giveCreatureHome(ulong guid, ulong cell)
    {
        const slot = slotFor(guid);
        if (slot != uint.max && !at(slot).replica)
            at(slot).home = cell;
    }

    /// Known unit replicas within the caller's assistance radius.
    Replica[] creatureReplicasNear(Position center, float range)
    {
        Replica[] result;
        foreach (slot; objectSlotsNear(center, range))
            if (auto replica = cast(Replica) at(slot).object)
                if (replica.fields.type == TypeId.unit)
                    result ~= replica;
        return result;
    }

    void delegate(Creature, UnitRef, float) remoteAssistance;

    bool mayAskRemoteAssistance() const { return remoteAssistance !is null; }

    void askRemoteAssistance(Creature caller, UnitRef enemy, float radius)
    {
        if (remoteAssistance !is null)
            remoteAssistance(caller, enemy, radius);
    }

    /// Cells were gained: every player looks around again, so those near them load, and so do cells other nodes want.
    void ownershipGained()
    {
        foreach (slot; players.dup)
            if (entities.holds(slot) && at(slot).player !is null)
                updateVisibility(at(slot).player);
        foreach (cell, _; peerCells)
            loadCell(cell);
    }

    // -----------------------------------------------------------------------
    // Replication
    // -----------------------------------------------------------------------

    /**
     * Node `peer` wants what this node simulates in the `added` cells, and no longer in the
     * `removed` ones: replicas go to it and away from it, and wanted cells this node owns load.
     */
    void peerInterest(ushort peer, const(ulong)[] added, const(ulong)[] removed)
    {
        foreach (cell; removed)
        {
            if (auto peers = cell in peerCells)
            {
                (*peers).remove(peer);
                if ((*peers).length == 0)
                    peerCells.remove(cell);
            }
            if (const list = cell in cellLists)
                foreach (slot; list.objects ~ list.players)
                    if (at(slot).replicatedTo.canFind(peer))
                    {
                        dropValue(at(slot).replicatedTo, peer);
                        replicator.remove(peer, id, at(slot).guid);
                    }
        }
        foreach (cell; added)
        {
            peerCells[cell][peer] = true;
            loadCell(cell); // replicates what it spawns
            if (const list = cell in cellLists)
            {
                foreach (slot; list.objects)
                    replicate(slot, cell);
                foreach (slot; list.players)
                    replicatePlayer(at(slot).player);
            }
        }
    }

    /// Node `peer` is gone: it holds no replicas any more, and those it sent go.
    void peerGone(ushort peer)
    {
        ulong[] emptied;
        foreach (cell, ref peers; peerCells)
            if (peers.remove(peer) && peers.length == 0)
                emptied ~= cell;
        foreach (cell; emptied)
            peerCells.remove(cell);
        ulong[] gone;
        foreach (slot, ref e; entities)
        {
            dropValue(e.replicatedTo, peer);
            if (e.replica && (cast(Replica) e.object).owner == peer)
                gone ~= e.guid;
        }
        forget(gone);
    }

    /// A replica of `guid`, simulated by node `owner`, in `cell` (`encodeState`).
    void replicaCreated(ushort owner, ulong cell, ulong guid, const(ubyte)[] state)
    {
        auto replica = makeReplica(guid, owner, state);
        const at_ = cellKeyAt(replica.position.x, replica.position.y);
        auto slot = slotFor(guid);
        if (slot != uint.max)
        {
            if (!at(slot).replica)
                return; // this node simulates it now: the message is from before the change
            // A newer replica of it, in its slot: its viewers keep seeing it.
            auto e = &at(slot);
            e.object = replica;
            e.mover = replica;
            e.visibilityAt = replica.position;
            if (e.cell != at_)
            {
                takeFromCell(slot);
                putInCell(slot, at_);
            }
            else
                updateObjectCollision(slot);
        }
        else
        {
            slot = newEntity(Entity(guid, null, replica, replica, true, noCell, 0, noCell, replica.position));
            ++replicaCount_;
            putInCell(slot, at_);
        }
        startTicking(slot);
        updateObjectVisibility(replica);
    }

    private Replica makeReplica(ulong guid, ushort owner, const(ubyte)[] state)
    {
        auto replica = new Replica(guid, owner, state);
        if (elevatorPath !is null && elevatorClock !is null && replica.fields.type == TypeId.gameObject)
            replica.setElevator(elevatorPath(guid, replica.fields), elevatorClock);
        return replica;
    }

    /// Fields of a replica changed on its owner.
    void replicaValues(ushort owner, ulong guid, const(ubyte)[] slots)
    {
        if (auto replica = replicaFrom(owner, guid))
        {
            const isPlayer = replica.fieldsOf.type == TypeId.player;
            const before = isPlayer ? viewOf(guid, replica.fieldsOf) : PlayerView.init;
            const lootViewChanged = replica.applySlots(slots);
            flushObjectChanges(replica);
            if (lootViewChanged)
                refreshViewers(replica);
            // Another node's player died, released or came back: who sees it may change (`playerSees`).
            if (isPlayer && viewOf(guid, replica.fieldsOf) != before)
                updateObjectVisibility(replica);
        }
    }

    /// A replica started or stopped a walk: its players get the packet the owner's players got.
    void replicaMoved(ushort owner, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
    {
        if (auto replica = replicaFrom(owner, guid))
        {
            replica.applyMotion(motion);
            startTicking(slotFor(guid));
            sendToObservers(guid, cast(Opcode) opcode, body_);
            objectRelocated(replica);
        }
    }

    /// A replica is no longer sent: it goes.
    void replicaRemoved(ushort owner, ulong guid)
    {
        if (replicaFrom(owner, guid) !is null)
            forget([guid]);
    }

    /// The cells this map started or stopped observing since the last call.
    void takeInterest(out ulong[] added, out ulong[] removed)
    {
        foreach (cell, _; interestAdded)
            added ~= cell;
        foreach (cell, _; interestRemoved)
            removed ~= cell;
        interestAdded = null;
        interestRemoved = null;
    }

    /// Every cell this map observes, for a node that just linked.
    ulong[] interestCells() const
    {
        return localInterest.keys;
    }

    /// Replicas of other nodes' objects on this map.
    @property size_t replicaCount() const
    {
        return replicaCount_;
    }

    /// Whether `guid` is a replica here.
    bool isReplica(ulong guid) const
    {
        const slot = slotFor(guid);
        return slot != uint.max && entities.at(slot).replica;
    }

    /// The terrain with its buildings, or null (the GM commands' collision queries).
    @property Terrain collision()
    {
        return terrain;
    }

    /// See `MotionWorld.groundHeight`.
    float groundHeight(float x, float y, float z, bool swim)
    {
        if (terrain is null)
            return invalidHeightValue;
        return terrain.heightStatic(x, y, z, true, swim ? defaultWaterSearch : defaultHeightSearch);
    }

    version (unittest)
    {
        /// Movement maps for a test: the way between two points.
        Vector3[] delegate(Vector3 from, Vector3 to) testPaths;
    }

    /// See `MotionWorld.pathBetween`.
    Vector3[] pathBetween(Vector3 from, Vector3 to)
    {
        version (unittest)
            if (testPaths !is null)
                return testPaths(from, to);
        if (terrain is null)
            return null;
        return terrain.pathBetween(from, to);
    }

    /// See `MotionWorld.swimmableAt`.
    bool swimmableAt(Vector3 at, float minimumDepth)
    {
        LiquidData water;
        return terrain !is null && terrain.swimmingVolume(at, minimumDepth, water);
    }

    /// See `MotionWorld.pathInWater`.
    bool pathInWater(Vector3 from, Vector3 to, float minimumDepth, out Vector3[] route)
    {
        import std.algorithm.comparison : clamp, min;
        import std.math : ceil, isFinite;

        LiquidData start, end;
        if (terrain is null || !terrain.swimmingVolume(from, minimumDepth, start)
            || !terrain.swimmingVolume(to, minimumDepth, end))
            return false;

        bool clear(Vector3 a, Vector3 b)
        {
            // Sample more closely than the terrain's liquid squares (roughly 4 yards apart).
            // Bound the work for large movements. A path that cannot be checked is not used.
            enum maxSegment = 512.0f;
            const length = (a - b).magnitude;
            if (!length.isFinite || length > maxSegment)
                return false;
            const samples = cast(uint) ceil(length / 2);
            foreach (i; 1 .. samples)
                if (!swimmableAt(a + (b - a) * (cast(float) i / samples), minimumDepth))
                    return false;
            return lineOfSightBetween(Position(a.x, a.y, a.z), Position(b.x, b.y, b.z));
        }

        if (clear(from, to))
        {
            route = [from, to];
            return true;
        }

        // The movement map marks water on the floor. Lift its corners to swim at a
        // suitable depth, then check the resulting segments against current geometry.
        auto way = terrain.pathBetween(Vector3(from.x, from.y, start.depthLevel),
            Vector3(to.x, to.y, end.depthLevel), true);
        if (way.length < 3)
            return true;
        const depth = min(start.level - from.z, end.level - to.z);
        way[0] = from;
        way[$ - 1] = to;
        foreach (i; 1 .. way.length - 1)
        {
            const corner = way[i];
            LiquidData water;
            const status = terrain.liquidStatus(corner.x, corner.y, corner.z, 0, water);
            enum clearance = 0.1f;
            if (status == LiquidStatus.noWater || water.level - water.depthLevel <= minimumDepth
                || water.level - water.depthLevel <= 2 * clearance)
                return true;
            way[i].z = clamp(water.level - depth, water.depthLevel + clearance, water.level - clearance);
        }
        foreach (i; 1 .. way.length)
            if (!clear(way[i - 1], way[i]))
                return true;
        route = way;
        return true;
    }

    /// See `MotionWorld.waterOrGroundLevel`.
    float waterOrGroundLevel(float x, float y, float z, float groundZ, float minWaterDeep)
    {
        if (terrain is null || terrain.tile(x, y) is null)
            return invalidHeightValue;
        enum ubyte allLiquids = 0x0F; // every liquid type
        LiquidData liquid;
        if (terrain.liquidStatus(x, y, groundZ, allLiquids, liquid) == LiquidStatus.noWater)
            return groundZ;
        // Deep enough to swim: just under the surface; shallow: on the ground.
        return liquid.level - groundZ > minWaterDeep ? liquid.level - minWaterDeep : groundZ;
    }

    /// See `MotionWorld.sendToObservers`: the object's viewers, and the peers holding a replica of it.
    void sendToObservers(ulong guid, Opcode opcode, const(ubyte)[] body_)
    {
        const slot = slotFor(guid);
        if (slot == uint.max)
            return;
        if (replicator !is null && !at(slot).replica && at(slot).replicatedTo.length)
            if (auto object = cast(Replicable) at(slot).object)
            {
                const motion = encodeMotion(object.motion(serverTime()));
                foreach (peer; at(slot).replicatedTo)
                    replicator.move(peer, id, guid, cast(ushort) opcode, body_, motion);
            }
        foreach (v; at(slot).viewers)
            at(v).player.deliver(opcode, body_);
    }

    /// See `CombatWorld.unit`.
    UnitRef unit(ulong guid)
    {
        import dmangos.world.character : Character;

        const slot = slotFor(guid);
        if (slot == uint.max)
            return UnitRef.init;
        if (auto session = cast(Character) at(slot).player)
            return UnitRef.of(session);
        return UnitRef.of(cast(Creature) at(slot).object, this);
    }

    /// See `CombatWorld.unitOf`.
    UnitRef unitOf(Creature creature)
    {
        return UnitRef.of(creature, this);
    }

    /// A player here as a unit; none for a stand-in (tests).
    private UnitRef unitOf(Inhabitant who)
    {
        import dmangos.world.character : Character;

        return UnitRef.of(cast(Character) who);
    }

    /**
     * A creature died of something no player is credited with (a creature's blow, a pet of its own):
     * `Creature.die`, and what the world does about a death (`onCreatureDeath`).
     */
    void creatureDeath(Creature creature)
    {
        if (onCreatureDeath !is null)
            onCreatureDeath(creature);
        else
            creature.die(this, 0);
    }

    /// Told to let a creature die (`WorldContext`: `die`, and the death queued).
    void delegate(Creature creature) onCreatureDeath;

    /// A player's damage aura ticked on a creature here after the caster left this map.
    void delegate(UnitRef victim, imported!"dmangos.world.auras".Aura aura, size_t effect) remotePeriodicTick;

    /// Sends a due melee swing from a creature here to its target's node.
    bool delegate(Creature attacker, UnitRef target, uint spell, int spellValue, float spellThreat, bool secondary)
        remoteCreatureSwing;

    /// Keep player replicas near this creature while it has an active fight, even without a local player.
    package void trackCreatureCombat(Creature creature, bool fighting)
    {
        const slot = objectSlot(creature);
        if (slot == uint.max)
            return;
        if (fighting && replicator !is null)
            updateInterest(slot, creature.position);
        else
            clearInterest(slot);
    }

    /// Told what linked creatures follow (`WorldContext`: `dmangos.world.creaturelinking`).
    void delegate(Map map, Creature source, LinkEvent event, ulong enemy) onLinked;

    /// See `CombatWorld.linked`.
    void linked(Creature source, LinkEvent event, ulong enemy)
    {
        if (onLinked !is null)
            onLinked(this, source, event, enemy);
    }

    /**
     * The creatures that died since the world last looked (docs/DESIGN.md, step 4): their dungeon's
     * script and their respawn time hear of it in the tick's deaths phase (`WorldContext.update`).
     */
    EventQueue!Creature creatureDeaths;

    /// Players on the map now (a copy: an update may move one away).
    Inhabitant[] playersNow()
    {
        Inhabitant[] found;
        snapshotPlayers(found);
        return found;
    }

    /// Copies the current player list into caller-owned storage.
    package void snapshotPlayers(ref Inhabitant[] found)
    {
        found.length = players.length;
        foreach (i, slot; players)
            found[i] = at(slot).player;
    }

    private void updateObjectCollision(uint slot)
    {
        if (objectCollision is null || slot == uint.max)
            return;
        if (auto object = at(slot).object)
            if (object.fields.type == TypeId.gameObject)
                objectCollision.update(slot, object.fields, object.position);
    }

    /// Whether static geometry or a closed door stands between the exact endpoints.
    bool lineOfSightBetween(Position a, Position b)
    {
        if (terrain !is null && !terrain.isInLineOfSight(a.x, a.y, a.z, b.x, b.y, b.z))
            return false;
        return objectCollision is null || !objectCollision.obstructs(a, b, (uint slot) {
            return at(slot).object.fields.get!GAMEOBJECT_STATE == goStateReady;
        });
    }

    /// See `CombatWorld.inLineOfSight`: terrain and objects at eye height.
    bool inLineOfSight(Position a, Position b)
    {
        enum eyes = 2.0f;
        a.z += eyes;
        b.z += eyes;
        return lineOfSightBetween(a, b);
    }

    /// Tests: water everywhere at this level (NaN: as the terrain says).
    float waterForTests = float.nan;

    /// The water's surface at (x, y) near `z`, if there is water there;
    /// without terrain (tests) everything is water at `z`.
    bool waterAt(float x, float y, float z, out float level)
    {
        if (waterForTests != float.nan && waterForTests == waterForTests)
        {
            level = waterForTests;
            return true;
        }
        if (terrain is null)
        {
            level = z;
            return true;
        }
        enum ubyte allLiquids = 0x0F; // every liquid type
        LiquidData liquid;
        if (terrain.liquidStatus(x, y, z, allLiquids, liquid) == LiquidStatus.noWater)
            return false;
        level = liquid.level;
        return true;
    }

    /// See `CombatWorld.creaturesNear`.
    Creature[] creaturesNear(Position center, float range)
    {
        Creature[] found;
        foreach (slot; objectSlotsNear(center, range))
            if (auto creature = cast(Creature) at(slot).object)
                found ~= creature;
        return found;
    }

    /// See `CombatWorld.creatureAt`.
    Creature creatureAt(ulong guid)
    {
        const slot = slotFor(guid);
        return slot == uint.max ? null : cast(Creature) at(slot).object;
    }

    /// See `CombatWorld.gameObjectAt`.
    GameObject gameObjectAt(ulong guid)
    {
        const slot = slotFor(guid);
        return slot == uint.max ? null : cast(GameObject) at(slot).object;
    }

    /// See `CombatWorld.positionOf`.
    bool positionOf(ulong guid, out Position at_)
    {
        const slot = slotFor(guid);
        if (slot == uint.max)
            return false;
        at_ = at(slot).player !is null ? at(slot).player.character.position : at(slot).object.position;
        return true;
    }

    /// See `CombatWorld.playersNear`.
    UnitRef[] playersNear(Position center, float range)
    {
        UnitRef[] found;
        foreach (inhabitant; near(center, range))
            if (auto u = unitOf(inhabitant))
                found ~= u;
        return found;
    }

    /// Told when a creature reaches a waypoint with a script.
    void delegate(Creature creature, uint scriptId) onWaypointScript;

    /// See `MotionWorld.waypointScript`.
    void waypointScript(Creature creature, uint scriptId)
    {
        if (onWaypointScript !is null)
            onWaypointScript(creature, scriptId);
    }

    /// Told when an object leaves this map for good (gone, or handed to another node) after its state was saved.
    void delegate(MapObject object) onObjectGone;

    /// Open-world round 2: an object became this map's own (spawned with its cell, put here, or handed over).
    void delegate(MapObject object) onObjectArrived;

    /// Every object here, replicas included.
    void forEachObject(scope void delegate(MapObject object) each)
    {
        MapObject[] all;
        foreach (slot, ref e; entities)
            if (e.object !is null)
                all ~= e.object;
        foreach (object; all)
            each(object);
    }

    /// Told when a creature's corpse goes, to bring it back later; null: never comes back.
    void delegate(Creature creature) onCorpseRemoved;

    /// See `CombatWorld.corpseExpired`.
    void corpseExpired(Creature creature)
    {
        removeObject(creature.guid);
        if (onCorpseRemoved !is null)
            onCorpseRemoved(creature);
    }

    /// Told when a game object is used up, to bring it back later.
    void delegate(GameObject go) onGameObjectUsedUp;

    /// See `GameObjectWorld.flushGameObject`.
    void flushGameObject(GameObject go)
    {
        flushObjectChanges(go);
    }

    /// See `GameObjectWorld.gameObjectUsedUp`.
    void gameObjectUsedUp(GameObject go)
    {
        removeObject(go.guid);
        if (onGameObjectUsedUp !is null)
            onGameObjectUsedUp(go);
    }

    /// See `CombatWorld.flushCreature`.
    void flushCreature(Creature creature)
    {
        flushObjectChanges(creature);
    }

    /// How far away a creature can notice a player at all: the widest aggro radius (`Detection` and 25 levels).
    enum float noticeDistance = 50;

    /// The creatures a player sees notice it, when it has moved (`CreatureAI.moveInLineOfSight`).
    private void playerNoticed(Inhabitant who, uint slot)
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.objects : HighGuid, highGuidOf;
        import dmangos.world.updatefields;

        auto combatant = unitOf(who);
        if (!combatant)
            return;
        const atNow = who.character.position;
        auto known = borrowList();
        scope (exit)
            giveBackList(known);
        knownInto(slot, false, known);
        foreach (k; known)
        {
            if (who.character is null)
                return; // a notice can move the player to another node
            if (!entities.holds(k) || at(k).object is null)
                continue; // gone as an earlier one acted
            auto object = at(k).object;
            if (auto creature = cast(Creature) object)
            {
                if (creature.ai !is null && creature.ai.mayNotice
                    && distanceSquared(creature.position, atNow) < noticeDistance ^^ 2)
                    creature.ai.moveInLineOfSight(combatant, this);
            }
            else if (auto go = cast(GameObject) object)
            {
                // A trap within whose radius the player now stands.
                const radius = go.trapRadius;
                if (radius > 0 && onTrap !is null && distanceSquared(go.position, atNow) <= radius * radius)
                    onTrap(who, go);
            }
            else if (onReplicaNoticing !is null && highGuidOf(at(k).guid) == HighGuid.unit)
                if (auto replica = cast(Replica) object)
                {
                    // Another node's creature, alive and not fighting: would it notice the player?
                    const values = &replica.fields();
                    if (values.get!UNIT_FIELD_HEALTH > 0 && !(values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat)
                        && distanceSquared(replica.position, atNow) < noticeDistance ^^ 2)
                        onReplicaNoticing(who, replica);
                }
        }
    }

    /// Told when a player steps within a trap's radius (it may spring).
    void delegate(Inhabitant who, GameObject trap) onTrap;

    /**
     * Told of another node's creature (its replica here, alive, out of combat) near a player who
     * moved, to decide whether it notices the player (and the player must go to that node to fight).
     */
    void delegate(Inhabitant who, Replica replica) onReplicaNoticing;

    /// The players who see a creature are noticed by it, when it has moved; a pet that moved is noticed by the creatures near it.
    private void creatureNoticing(Creature creature, uint slot)
    {
        if (creature.petOwner)
        {
            if (!creature.alive)
                return;
            auto pet = unitOf(creature);
            foreach (other; creaturesNear(creature.position, noticeDistance))
                if (other !is creature && !other.petOwner && other.ai !is null && other.ai.mayNotice
                        && !other.ai.inCombat && !other.ai.evading)
                    other.ai.moveInLineOfSight(pet, this);
            return;
        }
        // A creature a script set apart (an escortee on another faction, a summoned ambusher) is noticed by the
        // creatures near it that would attack it on sight: monsters fall on the escorted.
        if (creature.alive && creatureNoticeable(creature))
        {
            auto moving = unitOf(creature);
            foreach (other; creaturesNear(creature.position, noticeDistance))
                if (other !is creature && !other.petOwner && other.ai !is null && !other.ai.inCombat && !other.ai.evading
                        && other.ai.mayNotice)
                    other.ai.moveInLineOfSight(moving, this);
        }
        if (creature.ai is null || creature.ai.inCombat || creature.ai.evading || !creature.ai.mayNotice)
            return;
        // The players near it (by cell), of those that see it.
        foreach (p; playerSlotsNear(creature.position, noticeDistance))
            if (at(p).known[slot])
                if (auto combatant = unitOf(at(p).player))
                    creature.ai.moveInLineOfSight(combatant, this);
    }

    /**
     * Whether other creatures notice `creature` on sight, as they do players: one a script set apart, its faction
     * not its template's (an escortee, a creature turned hostile) or summoned by someone (an ambush). Creatures
     * of the world as spawned do not fall on each other.
     */
    private static bool creatureNoticeable(const Creature creature)
    {
        const own = creature.factionTemplate is null ? 0 : creature.factionTemplate.id;
        return own != creature.template_.faction || creature.summon.summoner != 0;
    }

    /// See `MotionWorld.random`.
    ref Random random()
    {
        return rng;
    }

    /// Number of players on the map.
    @property size_t population() const
    {
        return players.length;
    }

    /// Whether the players with guids `a` and `b` see each other.
    bool seeEachOther(ulong a, ulong b) const
    {
        const sa = slotFor(a), sb = slotFor(b);
        return sa != uint.max && sb != uint.max && entities.at(sa).player !is null && entities.at(sb).player !is null
            && entities.at(sa).known[sb];
    }

    /// The player with `guid` on this map, or null.
    Inhabitant find(ulong guid)
    {
        const slot = slotFor(guid);
        return slot == uint.max ? null : at(slot).player;
    }

    /// Raid scripts: a player was put on the map (`add`).
    void delegate(Inhabitant who) onPlayerAdded;

    /// Puts a player on the map, and introduces it to everyone in sight.
    void add(Inhabitant who, bool shipsShown = false)
    in (find(who.character.guid) is null, "a player is on a map once")
    {
        const guid = who.character.guid;
        auto slot = slotFor(guid);
        if (slot != uint.max) // a replica of it (it was simulated elsewhere): the player takes its slot
        {
            takeFromCell(slot);
            stopTicking(slot);
            auto e = &at(slot);
            e.object = null;
            e.mover = null;
            if (e.replica)
                --replicaCount_;
            e.replica = false;
            e.player = who;
        }
        else
            slot = newEntity(Entity(guid, who));
        players ~= slot;
        place(slot, who.character.position);
        updateVisibility(who);
        replicatePlayer(who);
        if (!shipsShown) // the session showed them already, before the player's own create block
            foreach (object; everywhere_)
                deliverUpdate(who, object.appearance(serverTime()));
        if (onPlayerAdded !is null) // Raid scripts: a copy's script hears of it
            onPlayerAdded(who);
    }

    private MapObject[] everywhere_; /// objects every player here sees wherever they are (ships)

    /// An object every player on the map sees wherever they are (a ship): shown to everyone here now, and to whoever comes.
    void addEverywhere(MapObject object)
    {
        foreach (o; everywhere_)
            if (o.guid == object.guid)
                return;
        everywhere_ ~= object;
        const time = serverTime();
        foreach (who; playersNow())
            deliverUpdate(who, object.appearance(time));
    }

    /// It leaves the map: everyone here is told to forget it.
    void removeEverywhere(ulong guid)
    {
        import std.algorithm.mutation : remove_ = remove;

        foreach (i, o; everywhere_)
            if (o.guid == guid)
            {
                everywhere_ = everywhere_.remove_(i);
                UpdateData forget;
                forget.addOutOfRange([guid]);
                foreach (who; playersNow())
                    deliverUpdate(who, forget);
                return;
            }
    }

    /// The objects seen from anywhere on the map.
    @property const(MapObject)[] everywhere() const
    {
        return everywhere_;
    }

    /// Takes a player off the map; those who saw it are told to destroy it.
    void remove(Inhabitant who)
    in (find(who.character.guid) !is null, "only a player on the map can leave it")
    {
        const guid = who.character.guid;
        const slot = slotFor(guid);
        clearInterest(slot);
        foreach (peer; at(slot).replicatedTo)
            replicator.remove(peer, id, guid);
        at(slot).replicatedTo = null;
        foreach (o; knownOf(slot, true))
            unsee(slot, o);
        foreach (v; at(slot).viewers.dup) // those who see it (not always those it sees: a ghost)
            if (at(v).player !is null)
            {
                unsee(v, slot);
                deliverPacket(at(v).player, ServerDestroyObject(guid));
            }
        if (at(slot).ghost)
            --ghosts;
        lingerUntil.remove(guid);
        dropEntity(slot);
    }

    /// After a player moved: updates its cell, and visibility if it moved far enough.
    void relocated(Inhabitant who)
    in (find(who.character.guid) !is null)
    {
        const slot = slotFor(who.character.guid);
        const position = who.character.position;
        if (place(slot, position))
            replicatePlayer(who);
        if (distanceSquared(at(slot).visibilityAt, position) >= settings.relocationLimit ^^ 2)
            updateVisibility(who);
        playerNoticed(who, slot);
    }

    /// Delivers a packet to every player that sees `from`, and to `from` itself if `includeSelf`.
    void sendToWatchers(Inhabitant from, Opcode opcode, const(ubyte)[] body_, bool includeSelf = false)
    {
        const slot = slotFor(from.character.guid);
        if (slot != uint.max && at(slot).replicatedTo.length)
        {
            const motion = encodeMotion(from.character.motionForOthers(serverTime()));
            foreach (peer; at(slot).replicatedTo)
                replicator.move(peer, id, from.character.guid, cast(ushort) opcode, body_, motion);
        }
        if (includeSelf)
            from.deliver(opcode, body_);
        if (slot != uint.max)
            foreach (v; at(slot).viewers)
                at(v).player.deliver(opcode, body_);
    }

    /// Each player that sees `from`, without making a list of them.
    void forEachWatcher(const Inhabitant from, scope void delegate(Inhabitant watcher) each)
    {
        const slot = slotFor(from.character.guid);
        if (slot == uint.max)
            return;
        foreach (v; at(slot).viewers)
            each(at(v).player);
    }

    /// The players `viewer` sees (whose objects its client has).
    Inhabitant[] seenBy(const Inhabitant viewer)
    {
        Inhabitant[] found;
        const slot = slotFor(viewer.character.guid);
        if (slot != uint.max)
            foreach (k; at(slot).known)
                if (auto p = at(k).player)
                    found ~= p;
        return found;
    }

    /// The players that see `from`.
    Inhabitant[] watchers(const Inhabitant from)
    {
        Inhabitant[] found;
        const slot = slotFor(from.character.guid);
        if (slot != uint.max)
            foreach (v; at(slot).viewers)
                found ~= at(v).player;
        return found;
    }

    /**
     * Delivers a packet to every player within `range` yards of `center`, whether they see each other or
     * not, on this node and on every other with players near.
     */
    void sendInRange(Position center, float range, Opcode opcode, const(ubyte)[] body_)
    {
        deliverInRange(center, range, opcode, body_);
        if (replicator is null)
            return;
        bool[ushort] peers;
        foreach (key; cellKeysNear(center, range))
            if (auto wanting = key in peerCells)
                foreach (peer, _; *wanting)
                    peers[peer] = true;
        foreach (peer, _; peers)
            replicator.inRange(peer, id, center, range, cast(ushort) opcode, body_);
    }

    /// `sendInRange` for this node's players only: what another node sent it (each node delivers to its own).
    void deliverInRange(Position center, float range, Opcode opcode, const(ubyte)[] body_)
    {
        foreach (who; near(center, range))
            who.deliver(opcode, body_);
    }

    /// The slots of the players within `range` yards of `center`.
    private uint[] playerSlotsNear(Position center, float range)
    {
        uint[] found;
        playerSlotsInto(center, range, found);
        return found;
    }

    /// What `playerSlotsNear` gives, appended to `found` (a list from `borrowList`).
    private void playerSlotsInto(Position center, float range, ref uint[] found)
    {
        foreach (key; cellKeysNear(center, range))
            if (const list = key in cellLists)
                foreach (slot; list.players)
                    if (distanceSquared(center, entities.at(slot).player.character.position) <= range ^^ 2)
                        found ~= slot;
    }

    /// The players within `range` yards of `center`.
    Inhabitant[] near(Position center, float range)
    {
        Inhabitant[] found;
        foreach (slot; playerSlotsNear(center, range))
            found ~= at(slot).player;
        return found;
    }

private:
    /**
     * Puts the object in the tick. One woken from a sleep (by its time, or by something giving it
     * something to do) keeps its last tick time, so its next tick counts the whole sleep; one that was
     * resting (or new) starts counting from now.
     */
    void startTicking(uint slot)
    {
        auto e = &at(slot);
        if (e.tickIndex != notTicking || e.mover is null)
            return;
        if (e.sleepToken)
        {
            e.sleepToken = 0; // its wheel entry is stale now
            --sleeping;
        }
        else
            e.lastTickAt = clockMs;
        e.tickIndex = cast(uint) ticking.length;
        ticking ~= slot;
    }

    /// Takes the object out of the tick until `wakeAt` (the map's clock; `ulong.max`: until woken).
    void sleep(uint slot, ulong wakeAt)
    {
        stopTicking(slot);
        auto e = &at(slot);
        e.sleepToken = ++sleepCounter ? sleepCounter : ++sleepCounter; // never 0
        ++sleeping;
        if (wakeAt != ulong.max)
            wheel[(wakeAt / wheelGrain) % wheelBuckets] ~= Sleeper(slot, e.sleepToken, wakeAt);
    }

    /**
     * The sleepers whose time has come go back in the tick: the wheel's buckets from the last one done
     * to the current one, which is looked at again next time (some of it may not be due yet).
     */
    void wakeSleepers()
    {
        const now = clockMs / wheelGrain;
        const first = wheelDone, buckets = now - wheelDone + 1 >= wheelBuckets ? wheelBuckets : now - wheelDone + 1;
        foreach (step; 0 .. buckets)
        {
            const index = (first + step) % wheelBuckets;
            if (wheel[index].length == 0)
                continue;
            Sleeper[] later;
            foreach (s; wheel[index])
            {
                if (!entities.holds(s.slot) || at(s.slot).sleepToken != s.token)
                    continue; // woken already, or gone
                if (s.wakeAt > clockMs)
                    later ~= s; // later in this bucket's time, or a later round
                else
                    startTicking(s.slot);
            }
            wheel[index] = later;
        }
        wheelDone = now;
    }

    void stopTicking(uint slot)
    {
        auto e = &at(slot);
        if (e.tickIndex == notTicking)
            return;
        const i = e.tickIndex, last = ticking[$ - 1];
        ticking[i] = last;
        at(last).tickIndex = i;
        ticking.length -= 1;
        ticking.assumeSafeAppend();
        e.tickIndex = notTicking;
    }

    /// Replicas of an own object for every peer that wants its cell and has none; removals for those that do not.
    void replicate(uint slot, ulong cell)
    {
        if (replicator is null || at(slot).replica)
            return;
        auto source = cast(Replicable) at(slot).object;
        if (source is null)
            return;
        replicateSlot(slot, cell, () => encodeState(source, serverTime()));
    }

    /// A local player, as `replicate` for objects: a replica on every node that wants its cell.
    void replicatePlayer(Inhabitant who)
    {
        if (replicator is null)
            return;
        const slot = slotFor(who.character.guid);
        replicateSlot(slot, at(slot).cell, () => encodePlayerState(who.character, serverTime()));
    }

    /// Replicas of what is in `slot` for the peers that want `cell`, and removals for the others.
    void replicateSlot(uint slot, ulong cell, scope const(ubyte)[] delegate() makeState)
    {
        const guid = at(slot).guid;
        auto wanted = cell in peerCells;
        foreach (peer; at(slot).replicatedTo.dup)
            if (wanted is null || peer !in *wanted)
            {
                dropValue(at(slot).replicatedTo, peer);
                replicator.remove(peer, id, guid);
            }
        if (wanted is null)
            return;
        const(ubyte)[] state;
        foreach (peer, _; *wanted)
            if (!at(slot).replicatedTo.canFind(peer))
            {
                if (state is null)
                    state = makeState();
                at(slot).replicatedTo ~= peer;
                replicator.create(peer, id, cell, guid, state);
            }
    }

    /// Objects go: the players who saw them are told, peers holding replicas of them too.
    void forget(const(ulong)[] gone)
    {
        ulong[][uint] lost; // viewer slot -> the guids it loses
        uint[] slots;
        foreach (guid; gone)
        {
            const slot = slotFor(guid);
            if (slot == uint.max || at(slot).object is null)
                continue;
            slots ~= slot;
            foreach (v; at(slot).viewers)
                lost[v] ~= guid;
        }
        foreach (v, guids; lost)
        {
            UpdateData forget;
            forget.addOutOfRange(guids);
            deliverUpdate(at(v).player, forget);
        }
        foreach (slot; slots)
        {
            if (!entities.holds(slot))
                continue;
            foreach (peer; at(slot).replicatedTo)
                replicator.remove(peer, id, at(slot).guid);
            at(slot).replicatedTo = null;
            if (onObjectGone !is null)
                onObjectGone(at(slot).object);
            if (entities.holds(slot))
                dropEntity(slot);
        }
    }

    /// The replica `guid`, if `owner` sends it.
    Replica replicaFrom(ushort owner, ulong guid)
    {
        const slot = slotFor(guid);
        if (slot == uint.max || !at(slot).replica)
            return null;
        auto replica = cast(Replica) at(slot).object;
        return replica.owner == owner ? replica : null;
    }

    /// The cells a local player or fighting creature is near now; the map's interest follows.
    void updateInterest(uint slot, Position position)
    {
        observeCells(slot, position, settings.visibilityDistance);
    }

    /// A ground effect observes its occupied cells even if its caster moves away from them.
    package void observeGroundArea(MapObject spot, float radius)
    {
        if (replicator !is null)
        {
            const slot = objectSlot(spot);
            if (slot != uint.max)
                observeCells(slot, spot.position, radius);
        }
    }

    private void observeCells(uint slot, Position position, float radius)
    {
        ulong[] near;
        foreach (cell; cellKeysNear(position, radius))
            near ~= cell;
        auto had = at(slot).interest;
        foreach (cell; near)
            if (!had.canFind(cell))
                if (localInterest.require(cell, 0)++ == 0)
                {
                    if (!interestRemoved.remove(cell))
                        interestAdded[cell] = true;
                }
        foreach (cell; had)
            if (!near.canFind(cell))
                dropInterest(cell);
        at(slot).interest = near;
    }

    private void clearInterest(uint slot)
    {
        foreach (cell; at(slot).interest)
            dropInterest(cell);
        at(slot).interest = null;
    }

    void dropInterest(ulong cell)
    {
        if (auto count = cell in localInterest)
            if (--*count == 0)
            {
                localInterest.remove(cell);
                if (!interestAdded.remove(cell))
                    interestRemoved[cell] = true;
            }
    }

    /// Puts a player in its cell; whether the cell changed.
    bool place(uint slot, Position position)
    {
        const key = cellKeyAt(position.x, position.y);
        if (at(slot).cell == key)
            return false;
        takeFromCell(slot);
        putInCell(slot, key);
        return true;
    }

    /**
     * Where `who` sees from: the object or unit in its `PLAYER_FARSIGHT` (Far Sight's and Eagle Eye's spot, the
     * unit under its Mind Vision) while that is on this map; else where it stands.
     */
    Position eyeOf(Inhabitant who, out bool far)
    {
        import dmangos.world.updatefields : PLAYER_FARSIGHT;

        const target = who.character.values.get!PLAYER_FARSIGHT;
        far = false;
        if (target == 0 || target == who.character.guid)
            return who.character.position;
        const slot = slotFor(target);
        if (slot == uint.max)
            return who.character.position;
        far = true;
        return at(slot).player !is null ? at(slot).player.character.position : at(slot).object.position;
    }

    /// Where the player in `slot` sees from (`eyeOf`, as of its last `updateVisibility`).
    private Position sightOf(uint slot)
    {
        return at(slot).farSeeing ? at(slot).eye : at(slot).player.character.position;
    }

    /// Whether the player in `viewer` sees as far as `position` (`visibilityDistance` from where it sees from).
    private bool inSightOf(uint viewer, Position position)
    {
        return distanceSquared(sightOf(viewer), position) <= settings.visibilityDistance ^^ 2;
    }

    /// Who sees whom, for every player near `who`, both ways.
    void updateVisibility(Inhabitant who)
    {
        const guid = who.character.guid;
        const slot = slotFor(guid);
        at(slot).visibilityAt = who.character.position;
        bool far;
        const eye = eyeOf(who, far);
        at(slot).farSeeing = far;
        at(slot).eye = eye;
        // One way: a ghost, an invisible game master, a stealthed player (the slot's `ghost` stands for all three).
        import dmangos.world.spellids : AuraType;

        // A far-seeing player too: it sees from one place and is seen at another.
        const ghost = who.character.deathState == DeathState.ghost || who.character.gmInvisible
            || who.character.auras.hasType(AuraType.modStealth) || who.character.auras.hasType(AuraType.modInvisibility)
            || far;
        const turned = ghost != at(slot).ghost;
        if (turned)
        {
            at(slot).ghost = ghost;
            ghost ? ++ghosts : --ghosts;
        }
        // No ghost on the map: everyone in sight sees each other, so what `who` knows is what knows `who`: no rule
        // to ask, no other player's set to read (a cache miss each, in a crowd), no pass over those who see it.
        // Not when `who` has just died or lived (its sets are still one way from before).
        const symmetric = ghosts == 0 && !turned;
        updateInterest(slot, who.character.position); // for peers, and for unloading idle cells

        // Who is in sight: a set kept by the map (its memory reused), emptied again on the way out. Not
        // reentered: nothing it calls updates another player's visibility.
        assert(!updatingVisibility, "updateVisibility reentered: its sets are the map's");
        updatingVisibility = true;
        scope (exit)
            updatingVisibility = false;
        auto near = borrowList();
        scope (exit)
            giveBackList(near);
        playerSlotsInto(who.character.position, settings.visibilityDistance, near);
        // What `who` sees is near its eye; who sees `who`, near where it stands (the same, unless far-seeing).
        auto seenNear = near;
        if (far)
        {
            seenNear = borrowList();
            playerSlotsInto(eye, settings.visibilityDistance, seenNear);
        }
        scope (exit)
            if (far)
                giveBackList(seenNear);
        alias inSight = playersInSight;
        foreach (o; seenNear)
            if (o != slot)
                inSight.add(o);
        scope (exit)
            foreach (o; seenNear)
                inSight.remove(o);

        // Newly in sight, each way on its own (a ghost and the living do not see each other alike,
        // `playerSees`): `who` gets the others' create blocks a packet's worth at a time; they get `who`'s,
        // built and compressed once for each kind of viewer (a crowd is one kind).
        const time = serverTime();
        UpdateData received;
        UpdatePacket[uint] shown;
        void iSeeIt(uint o, bool iSee)
        {
            if (iSee)
            {
                see(slot, o);
                const block = at(o).player.appearanceFor(who, time);
                if (!received.empty && received.byteSize + block.byteSize > maxUpdatePacketBytes)
                {
                    deliverUpdate(who, received);
                    received = UpdateData.init;
                }
                received.append(block);
            }
        }
        void itSeesMe(uint o, bool sees)
        {
            if (sees)
            {
                see(o, slot);
                auto other = at(o).player;
                const kind = who.appearanceKind(other);
                auto packet = kind in shown;
                if (packet is null)
                    packet = &(shown[kind] = who.appearanceFor(other, time).build());
                deliverBuilt(other, *packet);
            }
        }
        foreach (o; seenNear)
        {
            if (o == slot)
                continue;
            // Only `who`'s own set is read for a pair already known (the other's entry is a cache miss each).
            const iSee = !at(slot).known[o] && (symmetric || playerSeesSlot(slot, o));
            iSeeIt(o, iSee);
            if (!far) // the same players see `who`
                itSeesMe(o, symmetric ? iSee : !at(o).known[slot] && (!at(o).farSeeing
                    || inSightOf(o, who.character.position)) && playerSeesSlot(o, slot));
        }
        if (far)
            foreach (o; near)
                if (o != slot)
                    itSeesMe(o, !at(o).known[slot] && (!at(o).farSeeing || inSightOf(o, who.character.position))
                        && playerSeesSlot(o, slot));
        if (!received.empty)
            deliverUpdate(who, received);

        // Out of sight, or no longer seen: `who` forgets those in one block, and those who no longer see `who`
        // forget it.
        ulong[] gone;
        auto knownPlayers = borrowList();
        scope (exit)
            giveBackList(knownPlayers);
        knownInto(slot, true, knownPlayers);
        void forgetMe(uint v)
        {
            unsee(v, slot);
            UpdateData forget;
            forget.addOutOfRange([guid]);
            deliverUpdate(at(v).player, forget);
        }
        foreach (o; knownPlayers)
            if (!inSight[o] || (!symmetric && !playerSeesSlot(slot, o)))
            {
                gone ~= at(o).guid;
                unsee(slot, o);
                if (symmetric && at(o).known[slot])
                    forgetMe(o); // it saw `who` too
            }
        if (!symmetric)
        {
            auto watching = borrowList();
            scope (exit)
                giveBackList(watching);
            foreach (v; at(slot).viewers)
                if (at(v).player !is null)
                    watching ~= v;
            foreach (v; watching)
                if (!(far || at(v).farSeeing ? inSightOf(v, who.character.position) : inSight[v] != 0)
                        || !playerSeesSlot(v, slot))
                    forgetMe(v);
        }

        // Creatures and game objects: those that came into sight, in packets of a few dozen, and those that left.
        auto nearObjects = borrowList();
        scope (exit)
            giveBackList(nearObjects);
        objectSlotsInto(eye, settings.visibilityDistance, nearObjects, true);
        scope (exit)
            foreach (o; nearObjects)
                objectsInSight.remove(o);
        UpdateData created;
        MapObject[] personalAfter; // shown with a view of their own, after their create blocks
        foreach (o; nearObjects)
        {
            auto object = at(o).object;
            if (!objectVisibleTo(o, object, who, at(o).replica))
                continue;
            objectsInSight.add(o);
            if (!see(slot, o))
                continue;
            if (adoptLingering(slot, object.guid))
                continue;
            const block = object.appearance(time);
            if (!created.empty && (created.blockCount >= maxBlocksPerPacket
                || created.byteSize + block.byteSize > maxUpdatePacketBytes))
            {
                deliverUpdate(who, created);
                created = UpdateData.init;
            }
            created.append(block);
            if (cast(PerViewer) object !is null)
                personalAfter ~= object;
        }
        if (!created.empty)
            deliverUpdate(who, created);
        foreach (object; personalAfter)
            personalize(who, object);
        auto knownObjects = borrowList();
        scope (exit)
            giveBackList(knownObjects);
        knownInto(slot, false, knownObjects);
        foreach (o; knownObjects)
            if (!objectsInSight[o])
            {
                gone ~= at(o).guid;
                unsee(slot, o);
            }

        if (gone.length == 0)
            return;
        UpdateData forgetAll;
        forgetAll.addOutOfRange(gone);
        deliverUpdate(who, forgetAll);
    }

    /// An object moved: players it came near get it, those it left lose it.
    void updateObjectVisibility(MapObject object)
    {
        const slot = objectSlot(object);
        if (slot == uint.max)
            return;
        const guid = object.guid;
        foreach (p; playerSlotsNear(object.position, settings.visibilityDistance))
        {
            auto who = at(p).player;
            if (at(p).known[slot] || (at(p).farSeeing && !inSightOf(p, object.position))
                    || !objectVisibleTo(slot, object, who, at(slot).replica))
                continue;
            see(p, slot);
            if (adoptLingering(p, guid))
                continue; // the client has it already (it came from another node with it)
            deliverUpdate(who, object.appearance(serverTime()));
            personalize(who, object);
        }
        foreach (p; at(slot).viewers.dup)
            if (!inSightOf(p, object.position)
                || (at(slot).replica && !objectVisibleTo(slot, object, at(p).player, true))) // another node's ghost
            {
                unsee(p, slot);
                UpdateData forget;
                forget.addOutOfRange([guid]);
                deliverUpdate(at(p).player, forget);
            }
    }

    /// The keys of the cells that can hold something within `range` yards of `center`, row by row.
    static auto cellKeysNear(Position center, float range)
    {
        import std.algorithm.iteration : joiner, map;
        import std.range : iota;

        const reach = cast(int)(range / cellSize) + 1;
        const cx = cellCoordinate(center.x), cy = cellCoordinate(center.y);
        return iota(cx - reach, cx + reach + 1)
            .map!(x => iota(cy - reach, cy + reach + 1).map!(y => cellKey(x, y)))
            .joiner;
    }

    static float distanceSquared(Position a, Position b) pure nothrow @nogc @safe
    {
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
    }
}

version (unittest)
{
    import std.algorithm.searching : count;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.player : CharacterData;
    import dmangos.world.playercreate : CharacterBuilder, CreationSettings, KnownAbilities;
    import dmangos.world.testdata;

    /// A player that records what it is sent.
    private final class Watcher : Inhabitant
    {
        Player player;
        Opcode[] received;

        this(uint guid, Position position)
        {
            auto client = testClientData();
            auto world = testWorldData(client);
            CharacterData c;
            c.guid = guid;
            c.race = raceHuman;
            c.classId = classWarrior;
            c.level = 1;
            c.position = position;
            KnownAbilities abilities;
            new CharacterBuilder(world, client, CreationSettings.init, () => 1u).loadAbilities(c.race, c.classId,
                c.level, AccountLevel.player, null, null, abilities);
            player = new Player(c, abilities, world, client, testItemGuids());
        }

        @property const(Player) character() const
        {
            return player;
        }

        uint kind;          // the version of its block others get (as a group would set it)
        size_t built;       // how often its create block was built

        UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const
        {
            ++(cast() this).built;
            return player.createForOthers(serverTime, false);
        }

        uint appearanceKind(const Inhabitant viewer) const
        {
            return (cast(const Watcher) viewer).kind == kind ? 0 : 1;
        }

        void deliver(Opcode opcode, const(ubyte)[] body_)
        {
            received ~= opcode;
        }

        void moveTo(float x, float y)
        {
            player.movement.position.x = x;
            player.movement.position.y = y;
        }

        Opcode[] take()
        {
            auto got = received;
            received = null;
            return got;
        }
    }
}

unittest
{
    auto map = new Map(0, MapSettings.init, () => 1000u);
    auto alice = new Watcher(1, Position(0, 0, 0));
    auto bob = new Watcher(2, Position(50, 0, 0));
    auto carol = new Watcher(3, Position(500, 0, 0));

    // Joining: those in sight are introduced to each other.
    map.add(alice);
    assert(alice.take() == []);
    map.add(bob);
    assert(map.seeEachOther(1, 2) && map.seeEachOther(2, 1));
    assert(alice.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]
        && bob.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]);
    map.add(carol);
    assert(!map.seeEachOther(1, 3) && carol.take() == [] && map.population == 3);

    // Messages: to watchers, or to everyone in range.
    const ubyte[1] body_ = [1];
    map.sendToWatchers(bob, Opcode.MSG_MOVE_HEARTBEAT, body_);
    assert(alice.take() == [Opcode.MSG_MOVE_HEARTBEAT] && bob.take() == [] && carol.take() == []);
    map.sendInRange(Position(0, 0, 0), 25, Opcode.SMSG_MESSAGECHAT, body_);
    assert(alice.take() == [Opcode.SMSG_MESSAGECHAT] && bob.take() == [], "bob is 50 yards away");
    assert(map.near(Position(400, 0, 0), 150) == [cast(Inhabitant) carol]);
    assert(map.watchers(alice) == [cast(Inhabitant) bob] && map.watchers(carol).length == 0);

    // Small moves do not recompute visibility; crossing the distance does, both ways.
    bob.moveTo(55, 0);
    map.relocated(bob);
    assert(alice.take() == [] && bob.take() == []);
    bob.moveTo(450, 0);
    map.relocated(bob);
    assert(!map.seeEachOther(1, 2) && map.seeEachOther(2, 3));
    assert(alice.take() == [Opcode.SMSG_UPDATE_OBJECT], "an out-of-range block");
    assert(bob.take().length == 2 && carol.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]);

    // Leaving: those who saw the player destroy it.
    map.remove(bob);
    assert(carol.take() == [Opcode.SMSG_DESTROY_OBJECT] && alice.take() == [] && map.population == 2);
    assert(map.find(2) is null && map.find(1) is alice);
}

/// Far Sight: a player sees from its eye (here a player far off), and is still seen where it stands.
unittest
{
    import dmangos.world.updatefields : PLAYER_FARSIGHT;

    auto map = new Map(0, MapSettings.init, () => 1000u);
    auto alice = new Watcher(1, Position(0, 0, 0));
    auto bob = new Watcher(2, Position(50, 0, 0));
    auto carol = new Watcher(3, Position(500, 0, 0));
    map.add(alice);
    map.add(bob);
    map.add(carol);

    alice.player.values.set!PLAYER_FARSIGHT(carol.player.guid);
    map.refreshVisibility(alice);
    assert(map.seeEachOther(1, 3) && !map.seeEachOther(1, 2), "alice sees what is near her eye, not bob");
    assert(map.seeEachOther(2, 1) && !map.seeEachOther(3, 1), "bob still sees her; carol does not");

    // Bob moving far enough to work out his sight again does not take alice from him, nor carol from her.
    bob.moveTo(70, 0);
    map.relocated(bob);
    assert(map.seeEachOther(2, 1) && map.seeEachOther(1, 3));

    alice.player.values.set!PLAYER_FARSIGHT(0UL);
    map.refreshVisibility(alice);
    assert(map.seeEachOther(1, 2) && !map.seeEachOther(1, 3) && map.seeEachOther(2, 1));
}

/// Creatures and game objects: cells load when a player comes near, and objects come and go with sight.
unittest
{
    import dmangos.world.updatefields : TypeId;

    static final class Thing : MapObject
    {
        ulong id;
        Position at;
        UpdateValues values = UpdateValues(TypeId.gameObject);
        this(ulong id, Position at) { this.id = id; this.at = at; }
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return id; }
        @property Position position() const { return at; }
        UpdateData appearance(uint) const
        {
            import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
            import dmangos.world.updatefields : Visibility;

            UpdateData update;
            MovementBlock block;
            block.flags = UpdateFlags.hasPosition;
            auto values = UpdateValues(TypeId.gameObject);
            update.addCreate(UpdateType.createObject, id, block, values, Visibility.public_);
            return update;
        }
    }

    ulong[] loaded;
    MapObject[] spawner(uint, ulong cell)
    {
        loaded ~= cell;
        if (cell == cellKeyAt(10, 0))
            return [new Thing(0xF110_0000_0000_0001, Position(10, 0, 0)),
                new Thing(0xF110_0000_0000_0002, Position(60, 0, 0))];
        return null;
    }

    auto map = new Map(0, MapSettings.init, () => 1000u, &spawner);
    auto alice = new Watcher(1, Position(0, 0, 0));
    map.add(alice);
    assert(map.objectCount == 2 && map.seesObject(1, 0xF110_0000_0000_0001)
        && map.seesObject(1, 0xF110_0000_0000_0002));
    assert(alice.take() == [Opcode.SMSG_UPDATE_OBJECT], "both objects in one packet");
    const cellsLoaded = loaded.length;

    // Walking 120 yards on: the first object is out of sight, the second still in; nothing loads twice.
    alice.moveTo(120, 0);
    map.relocated(alice);
    assert(!map.seesObject(1, 0xF110_0000_0000_0001) && map.seesObject(1, 0xF110_0000_0000_0002));
    assert(alice.take() == [Opcode.SMSG_UPDATE_OBJECT], "an out-of-range block");
    alice.moveTo(0, 0);
    map.relocated(alice);
    assert(map.seesObject(1, 0xF110_0000_0000_0001) && map.objectCount == 2);
    foreach (cell; loaded)
        assert(loaded.count(cell) == 1, "a cell is loaded once");
    assert(loaded.length >= cellsLoaded);
}

/// Objects that move: they tick, change cell, and come into and out of sight as they go.
unittest
{
    import dmangos.world.motion : MotionWorld;
    import dmangos.world.updatefields : TypeId;

    static final class Walker : Moving
    {
        Position at;
        UpdateValues values = UpdateValues(TypeId.unit);
        this(Position at) { this.at = at; }
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return 0xF130_0000_0000_0009; }
        @property Position position() const { return at; }
        UpdateData appearance(uint) const
        {
            import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
            import dmangos.world.updatefields : Visibility;

            UpdateData update;
            MovementBlock block;
            block.flags = UpdateFlags.hasPosition;
            auto values = UpdateValues(TypeId.unit);
            update.addCreate(UpdateType.createObject, guid, block, values, Visibility.public_);
            return update;
        }

        /// East at 100 yards a second, telling whoever sees it.
        @property bool resting() const { return false; }

        void tick(MotionWorld world, int diff)
        {
            at.x += diff / 10.0f;
            const ubyte[1] body_ = [0];
            world.sendToObservers(guid, Opcode.SMSG_MONSTER_MOVE, body_);
        }
    }

    import core.time : msecs;

    auto walker = new Walker(Position(0, 0, 0));
    MapObject[] spawner(uint, ulong cell)
    {
        return cell == cellKeyAt(0, 0) ? [cast(MapObject) walker] : null;
    }

    auto map = new Map(0, MapSettings.init, () => 1000u, &spawner);
    auto alice = new Watcher(1, Position(50, 0, 0));
    map.add(alice);
    assert(map.seesObject(1, walker.guid) && alice.take() == [Opcode.SMSG_UPDATE_OBJECT]);

    // Under a millisecond waits for the next tick; then it moves, and those who see it hear of it.
    map.update(500.usecs);
    assert(walker.at.x == 0 && alice.take() == []);
    map.update(600.usecs);
    assert(walker.at.x == 0.1f && alice.take() == [Opcode.SMSG_MONSTER_MOVE]);

    // 200 yards east: out of alice's sight, in its new cell.
    map.update(2000.msecs);
    assert(!map.seesObject(1, walker.guid) && alice.take() == [Opcode.SMSG_MONSTER_MOVE, Opcode.SMSG_UPDATE_OBJECT]);
    assert(map.objectsNear(walker.position, 1) == [cast(MapObject) walker]);
    assert(map.objectsNear(Position(0, 0, 0), 5).length == 0);

    // Alice follows; it comes back into sight when she does.
    alice.moveTo(210, 0);
    map.relocated(alice);
    assert(map.seesObject(1, walker.guid) && alice.take() == [Opcode.SMSG_UPDATE_OBJECT]);
}

/// Arriving in a crowd: the newcomer's block is built once per kind of viewer, and theirs reach it batched.
unittest
{
    auto map = new Map(0, MapSettings.init, () => 1000u);
    Watcher[] crowd;
    foreach (uint i; 1 .. 5)
    {
        crowd ~= new Watcher(i, Position(i, 0, 0));
        map.add(crowd[$ - 1]);
    }
    crowd[3].kind = 1; // in another group than the newcomer
    foreach (w; crowd)
    {
        w.take();
        w.built = 0;
    }

    auto newcomer = new Watcher(9, Position(0, 1, 0));
    map.add(newcomer);
    assert(newcomer.built == 2, "one build for the three like it, one for the one in another group");
    assert(newcomer.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT], "the four blocks in one packet");
    foreach (w; crowd)
        assert(w.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT] && w.built == 1);
}

/// Ownership: unowned cells do not spawn; a released region's objects go, and come back when regained.
unittest
{
    import dmangos.world.updatefields : TypeId;

    static final class Stone : MapObject
    {
        ulong id;
        Position at;
        UpdateValues values = UpdateValues(TypeId.gameObject);
        this(ulong id, Position at) { this.id = id; this.at = at; }
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return id; }
        @property Position position() const { return at; }
        UpdateData appearance(uint) const
        {
            import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
            import dmangos.world.updatefields : Visibility;

            UpdateData update;
            MovementBlock block;
            block.flags = UpdateFlags.hasPosition;
            auto values = UpdateValues(TypeId.gameObject);
            update.addCreate(UpdateType.createObject, id, block, values, Visibility.public_);
            return update;
        }
    }

    enum ulong west = 0xF110_0000_0000_0001, east = 0xF110_0000_0000_0002;
    MapObject[] spawner(uint, ulong cell)
    {
        if (cell == cellKeyAt(-10, 0))
            return [new Stone(west, Position(-10, 0, 0))];
        if (cell == cellKeyAt(10, 0))
            return [new Stone(east, Position(10, 0, 0))];
        return null;
    }
    bool eastOwned = false;
    bool owns(ulong cell)
    {
        return cell != cellKeyAt(10, 0) || eastOwned;
    }

    auto map = new Map(0, MapSettings.init, () => 1000u, &spawner, null, &owns);
    auto alice = new Watcher(1, Position(0, 0, 0));
    map.add(alice);
    alice.take();
    assert(map.findObject(west) !is null && map.findObject(east) is null, "the east cell is not this node's");

    // The east cell is gained: alice sees its stone without moving.
    eastOwned = true;
    map.ownershipGained();
    assert(map.findObject(east) !is null && map.seesObject(1, east) && alice.take() == [Opcode.SMSG_UPDATE_OBJECT]);

    // It is lost again: the stone goes, and alice is told.
    eastOwned = false;
    map.release((ulong cell) => cell == cellKeyAt(10, 0));
    assert(map.findObject(east) is null && !map.seesObject(1, east) && map.findObject(west) !is null);
    assert(alice.take() == [Opcode.SMSG_UPDATE_OBJECT], "an out-of-range block");
    assert(map.objectCount == 1);
}

/// Replication: another node's player sees this node's objects, their changes and moves, and their going.
unittest
{
    import dmangos.world.motion : MotionWorld;
    import dmangos.world.objects : MovementBlock, UpdateFlags;
    import dmangos.world.replication : Replicable, Replicator;
    import dmangos.world.updatefields;

    // An owned object that the test moves by hand.
    static final class Boar : Replicable, Moving
    {
        Position at;
        UpdateValues values = UpdateValues(TypeId.unit);
        this(Position at)
        {
            this.at = at;
            values.set!OBJECT_FIELD_GUID(guid);
            values.set!UNIT_FIELD_HEALTH(50u);
            values.clearChanges();
        }
        @property ulong guid() const { return 0xF130_0000_0000_0042; }
        @property Position position() const { return at; }
        ref UpdateValues fields() { return values; }
        MovementBlock motion(uint time) const
        {
            MovementBlock m;
            m.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
            m.info.position = at;
            m.info.time = time;
            return m;
        }
        UpdateData appearance(uint time) const
        {
            import dmangos.world.objects : UpdateType;

            UpdateData u;
            auto m = motion(time);
            u.addCreate(UpdateType.createObject, guid, m, values, seenByEveryone);
            return u;
        }
        void tick(MotionWorld, int) {}
        @property bool resting() const { return true; }
    }

    // Two maps as two nodes would hold them, with what goes between them carried at once.
    static final class Wire : Replicator
    {
        Map[ushort] node;
        ushort from;
        void create(ushort peer, uint, ulong cell, ulong guid, const(ubyte)[] state) { node[peer].replicaCreated(owner: from, cell: cell, guid: guid, state); }
        void values(ushort peer, uint, ulong guid, const(ubyte)[] slots) { node[peer].replicaValues(from, guid, slots); }
        void move(ushort peer, uint, ulong guid, ushort op, const(ubyte)[] b, const(ubyte)[] m) { node[peer].replicaMoved(from, guid, op, b, m); }
        void remove(ushort peer, uint, ulong guid) { node[peer].replicaRemoved(from, guid); }
        void inRange(ushort peer, uint, Position c, float r, ushort op, const(ubyte)[] b) { node[peer].deliverInRange(c, r, cast(Opcode) op, b); }
    }

    auto boar = new Boar(Position(500, 0, 0));
    MapObject[] spawner(uint, ulong cell)
    {
        return cell == cellKeyAt(500, 0) ? [cast(MapObject) boar] : null;
    }
    // Node 1 owns everything east of x = 400; node 2 the rest.
    auto owner = new Map(0, MapSettings.init, () => 1000u, &spawner, null, (ulong cell) => cast(int)(cell >> 32) >= 6);
    auto viewer = new Map(0, MapSettings.init, () => 1000u, &spawner, null, (ulong cell) => cast(int)(cell >> 32) < 6);
    auto wire = new Wire;
    wire.from = 1;
    wire.node[2] = viewer;
    owner.replicator = wire;
    auto back = new Wire;
    back.from = 2;
    back.node[1] = owner;
    viewer.replicator = back;

    // A player on node 2, 50 yards from the boar: node 2 tells node 1 where it is interested.
    auto alice = new Watcher(1, Position(450, 0, 0));
    viewer.add(alice);
    assert(viewer.objectCount == 0 && owner.objectCount == 0, "node 2 does not own the boar's cell");
    ulong[] added, removed;
    viewer.takeInterest(added, removed);
    assert(added.length == 25 && removed.length == 0);
    alice.take();
    owner.peerInterest(2, added, removed);
    assert(owner.objectCount == 1, "node 1 loaded the cell for node 2");
    assert(viewer.replicaCount == 1 && viewer.isReplica(boar.guid) && viewer.seesObject(1, boar.guid));
    static bool oneUpdate(Opcode[] got)
    {
        return got.length == 1 && (got[0] == Opcode.SMSG_UPDATE_OBJECT || got[0] == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT);
    }
    assert(oneUpdate(alice.take()), "the boar's create block");
    import core.time : msecs;

    viewer.update(1.msecs);
    assert(viewer.tickingCount == 0, "a replica that is not walking leaves the tick");

    // Its health changes; it walks.
    boar.values.set!UNIT_FIELD_HEALTH(20u);
    owner.flushObjectChanges(boar);
    assert(viewer.findObject(boar.guid).fields[UNIT_FIELD_HEALTH] == 20);
    assert(oneUpdate(alice.take()), "a values block");
    boar.at = Position(510, 0, 0);
    const ubyte[1] body_ = [7];
    owner.sendToObservers(boar.guid, Opcode.SMSG_MONSTER_MOVE, body_);
    assert(alice.take() == [Opcode.SMSG_MONSTER_MOVE] && viewer.findObject(boar.guid).position.x == 510);

    // It runs off out of node 2's interest: its replica goes.
    boar.at = Position(900, 0, 0);
    owner.objectRelocated(boar);
    assert(viewer.replicaCount == 0 && !viewer.seesObject(1, boar.guid));
    assert(oneUpdate(alice.take()), "an out-of-range block");

    // Back again, then node 1 is lost: the replica goes with it.
    boar.at = Position(500, 0, 0);
    owner.objectRelocated(boar);
    assert(viewer.replicaCount == 1);
    alice.take();
    viewer.peerGone(1);
    assert(viewer.replicaCount == 0 && oneUpdate(alice.take()));

    // Alice walks away: the interest shrinks, and node 1 stops sending.
    alice.moveTo(-500, 0);
    viewer.relocated(alice);
    viewer.takeInterest(added, removed);
    assert(added.length == 25 && removed.length == 25);
    owner.peerInterest(2, added, removed);
    assert(owner.replicaCount == 0);
}

/// Players on different nodes: each sees the other's replica, its moves, its changes and its going.
unittest
{
    import dmangos.world.replication : Replicator;
    import dmangos.world.updatefields;

    static final class Wire : Replicator
    {
        Map to;
        ushort from;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state) { to.replicaCreated(owner: from, cell: cell, guid: guid, state); }
        void values(ushort, uint, ulong guid, const(ubyte)[] slots) { to.replicaValues(from, guid, slots); }
        void move(ushort, uint, ulong guid, ushort op, const(ubyte)[] b, const(ubyte)[] m) { to.replicaMoved(from, guid, op, b, m); }
        void remove(ushort, uint, ulong guid) { to.replicaRemoved(from, guid); }
        void inRange(ushort, uint, Position c, float r, ushort op, const(ubyte)[] b) { to.deliverInRange(c, r, cast(Opcode) op, b); }
    }
    static bool has(const(Opcode)[] got, Opcode op)
    {
        foreach (o; got)
            if (o == op)
                return true;
        return false;
    }

    auto one = new Map(0, MapSettings.init, () => 1000u);
    auto two = new Map(0, MapSettings.init, () => 1000u);
    auto toTwo = new Wire, toOne = new Wire;
    toTwo.to = two, toTwo.from = 1;
    toOne.to = one, toOne.from = 2;
    one.replicator = toTwo;
    two.replicator = toOne;
    void exchangeInterest()
    {
        ulong[] added, removed;
        one.takeInterest(added, removed);
        two.peerInterest(1, added, removed);
        two.takeInterest(added, removed);
        one.peerInterest(2, added, removed);
    }

    auto alice = new Watcher(1, Position(0, 0, 0));
    auto bob = new Watcher(2, Position(30, 0, 0));
    one.add(alice);
    two.add(bob);
    exchangeInterest();
    assert(one.isReplica(2) && two.isReplica(1), "each node holds the other's player");
    assert(one.seesObject(1, 2) && two.seesObject(2, 1));
    assert(one.findObject(2).fields[OBJECT_FIELD_GUID] == 2);
    alice.take();
    bob.take();

    // Bob moves: alice gets the very packet bob's watchers would.
    bob.moveTo(40, 0);
    two.relocated(bob);
    const ubyte[1] heartbeat = [9];
    two.sendToWatchers(bob, Opcode.MSG_MOVE_HEARTBEAT, heartbeat);
    assert(alice.take() == [Opcode.MSG_MOVE_HEARTBEAT] && one.findObject(2).position.x == 40);

    // Bob's health changes: alice sees it as a stranger does, in percent.
    bob.player.values.set!UNIT_FIELD_MAXHEALTH(200u);
    bob.player.values.set!UNIT_FIELD_HEALTH(50u);
    two.playerChanged(bob);
    bob.player.clearChanges();
    assert(one.findObject(2).fields[UNIT_FIELD_HEALTH] == 25 && one.findObject(2).fields[UNIT_FIELD_MAXHEALTH] == 100);
    const told = alice.take();
    assert(has(told, Opcode.SMSG_UPDATE_OBJECT) || has(told, Opcode.SMSG_COMPRESSED_UPDATE_OBJECT),
        "alice's client is told of the change");

    // Bob leaves: alice's node forgets him.
    two.remove(bob);
    assert(!one.isReplica(2) && !one.seesObject(1, 2));
}

/// Migration: a region's objects move to another node, and no player on any node notices.
unittest
{
    import core.time : msecs;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.migration : Migrant, MigrantKind;
    import dmangos.world.motion : MotionWorld;
    import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
    import dmangos.world.replication : Replicable, Replicator;
    import dmangos.world.updatefields;

    // A creature-like object whose whole state is its position and health.
    static final class Stag : Replicable, Moving
    {
        Position at;
        UpdateValues values = UpdateValues(TypeId.unit);
        this(Position at, uint health)
        {
            this.at = at;
            values.set!OBJECT_FIELD_GUID(guid);
            values.set!UNIT_FIELD_HEALTH(health);
            values.clearChanges();
        }
        @property ulong guid() const { return 0xF130_0000_0000_0077; }
        @property Position position() const { return at; }
        ref UpdateValues fields() { return values; }
        MovementBlock motion(uint time) const
        {
            MovementBlock m;
            m.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
            m.info.position = at;
            return m;
        }
        UpdateData appearance(uint time) const
        {
            UpdateData u;
            auto m = motion(time);
            u.addCreate(UpdateType.createObject, guid, m, values, seenByEveryone);
            return u;
        }
        void tick(MotionWorld, int) {}
        @property bool resting() const { return true; }
    }

    // Three nodes' maps, with what each sends carried to the others at once.
    static final class Wire : Replicator
    {
        Map[ushort] node;
        ushort from;
        void create(ushort peer, uint, ulong cell, ulong guid, const(ubyte)[] state) { node[peer].replicaCreated(owner: from, cell: cell, guid: guid, state); }
        void values(ushort peer, uint, ulong guid, const(ubyte)[] slots) { node[peer].replicaValues(from, guid, slots); }
        void move(ushort peer, uint, ulong guid, ushort op, const(ubyte)[] b, const(ubyte)[] m) { node[peer].replicaMoved(from, guid, op, b, m); }
        void remove(ushort peer, uint, ulong guid) { node[peer].replicaRemoved(from, guid); }
        void inRange(ushort peer, uint, Position c, float r, ushort op, const(ubyte)[] b) { node[peer].deliverInRange(c, r, cast(Opcode) op, b); }
    }

    Stag stag = new Stag(Position(500, 0, 0), 42);
    MapObject[] spawner(uint, ulong cell)
    {
        return cell == cellKeyAt(500, 0) ? [cast(MapObject) stag] : null;
    }
    bool aOwns = true;
    auto a = new Map(0, MapSettings.init, () => 1000u, &spawner, null, (ulong) => aOwns);
    auto b = new Map(0, MapSettings.init, () => 1000u, &spawner, null, (ulong) => !aOwns);
    auto c = new Map(0, MapSettings.init, () => 1000u, &spawner, null, (ulong) => false);
    Map[ushort] all = [1: a, 2: b, 3: c];
    foreach (ushort id, map; all)
    {
        auto wire = new Wire;
        wire.from = id;
        foreach (ushort other, m; all)
            if (other != id)
                wire.node[other] = m;
        map.replicator = wire;
    }
    void exchangeInterest()
    {
        foreach (ushort id, map; all)
        {
            ulong[] added, removed;
            map.takeInterest(added, removed);
            foreach (ushort other, m; all)
                if (other != id)
                    m.peerInterest(id, added, removed);
        }
    }

    auto onA = new Watcher(1, Position(480, 0, 0));
    auto onB = new Watcher(2, Position(520, 0, 0));
    auto onC = new Watcher(3, Position(500, 20, 0));
    a.add(onA);
    b.add(onB);
    c.add(onC);
    exchangeInterest();
    assert(!a.isReplica(stag.guid) && b.isReplica(stag.guid) && c.isReplica(stag.guid));
    foreach (w; [onA, onB, onC])
    {
        assert(w.player !is null);
        w.take();
    }
    assert(a.seesObject(1, stag.guid) && b.seesObject(2, stag.guid) && c.seesObject(3, stag.guid), "everyone sees it");

    // The region moves from node 1 to node 2, with the stag (now hurt) in it; a body that does not move
    // (a player's corpse) stays.
    static final class Body : MapObject
    {
        import dmangos.world.updatefields : TypeId;

        UpdateValues values = UpdateValues(TypeId.corpse);
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return 0xF101_0000_0000_0099; }
        @property Position position() const { return Position(495, 0, 0); }
        UpdateData appearance(uint) const { return UpdateData.init; }
    }
    auto corpseLike = new Body;
    a.addObject(corpseLike);
    foreach (w; [onA, onB, onC])
        w.take(); // its creation
    stag.values.set!UNIT_FIELD_HEALTH(13u);
    stag.values.clearChanges();
    aOwns = false;
    Stag restored;
    const bundle = a.migrateOut((ulong) => true, 2, (MapObject o) {
        if (cast(Stag) o is null)
            return Migrant.init;
        ByteWriter w;
        w.put((cast(Stag) o).values[UNIT_FIELD_HEALTH]);
        w.put((cast(Stag) o).at.x);
        return Migrant(MigrantKind.creature, 77, 0, w.data);
    });
    assert(a.isReplica(stag.guid), "node 1 keeps showing it, now as node 2's");
    assert(a.findObject(corpseLike.guid) is corpseLike, "the body stays");
    b.migrateIn(bundle, (const ref Migrant m) {
        auto r = ByteReader(m.state);
        const health = r.read!uint;
        restored = new Stag(Position(r.read!float, 0, 0), health);
        return cast(MapObject) restored;
    });
    assert(!b.isReplica(stag.guid) && b.findObject(stag.guid) is restored && restored.values[UNIT_FIELD_HEALTH] == 13);
    assert(a.isReplica(stag.guid) && c.isReplica(stag.guid), "the others hold node 2's replica now");
    foreach (w; [onA, onB, onC])
        assert(w.take() == [], "no client noticed anything");

    // It moves on its new owner: every client sees it.
    restored.at = Position(505, 0, 0);
    const ubyte[1] body_ = [1];
    b.sendToObservers(restored.guid, Opcode.SMSG_MONSTER_MOVE, body_);
    foreach (w; [onA, onB, onC])
        assert(w.take() == [Opcode.SMSG_MONSTER_MOVE]);
    assert(a.findObject(stag.guid).position.x == 505 && c.findObject(stag.guid).position.x == 505);
}

/// Migration: a migrant that finds a fresh spawn of itself replaces it; the migrated state wins.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.migration : encodeBundle, Migrant, MigrantKind;
    import dmangos.world.updatefields;

    static final class Pillar : MapObject
    {
        UpdateValues values = UpdateValues(TypeId.gameObject);
        this(uint state) { values.set!OBJECT_FIELD_ENTRY(state); }
        @property ulong guid() const { return 0xF110_0000_0000_0005; }
        @property Position position() const { return Position(5, 5, 0); }
        ref UpdateValues fields() { return values; }
        UpdateData appearance(uint) const
        {
            import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
            import dmangos.world.updatefields : Visibility;

            UpdateData u;
            MovementBlock block;
            block.flags = UpdateFlags.hasPosition;
            u.addCreate(UpdateType.createObject, guid, block, values, Visibility.public_);
            return u;
        }
    }
    MapObject[] spawner(uint, ulong cell)
    {
        return cell == cellKeyAt(5, 5) ? [cast(MapObject) new Pillar(1)] : null;
    }
    auto map = new Map(0, MapSettings.init, () => 1000u, &spawner);
    auto alice = new Watcher(1, Position(0, 0, 0));
    map.add(alice);
    assert(map.findObject(0xF110_0000_0000_0005).fields[OBJECT_FIELD_ENTRY] == 1, "spawned afresh");

    ByteWriter w;
    w.put(uint(2));
    const bundle = encodeBundle([cellKeyAt(5, 5)], [Migrant(MigrantKind.gameObject, 5, cellKeyAt(5, 5), w.data)]);
    map.migrateIn(bundle, (const ref Migrant m) {
        auto r = ByteReader(m.state);
        return cast(MapObject) new Pillar(r.read!uint);
    });
    assert(map.findObject(0xF110_0000_0000_0005).fields[OBJECT_FIELD_ENTRY] == 2, "the migrated state won");
    assert(map.objectCount == 1 && map.seesObject(1, 0xF110_0000_0000_0005));
}


/// Players moving between nodes: the handover sends nothing to anyone; what follows reaches everyone.
unittest
{
    import dmangos.world.replication : Replicator;

    static final class Wire : Replicator
    {
        Map to;
        ushort from;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state) { to.replicaCreated(owner: from, cell: cell, guid: guid, state); }
        void values(ushort, uint, ulong guid, const(ubyte)[] slots) { to.replicaValues(from, guid, slots); }
        void move(ushort, uint, ulong guid, ushort op, const(ubyte)[] b, const(ubyte)[] m) { to.replicaMoved(from, guid, op, b, m); }
        void remove(ushort, uint, ulong guid) { to.replicaRemoved(from, guid); }
        void inRange(ushort, uint, Position c, float r, ushort op, const(ubyte)[] b) { to.deliverInRange(c, r, cast(Opcode) op, b); }
    }

    auto home = new Map(0, MapSettings.init, () => 1000u);
    auto owner = new Map(0, MapSettings.init, () => 1000u);
    auto toOwner = new Wire, toHome = new Wire;
    toOwner.to = owner, toOwner.from = 1;
    toHome.to = home, toHome.from = 2;
    home.replicator = toOwner;
    owner.replicator = toHome;
    void exchangeInterest()
    {
        ulong[] added, removed;
        home.takeInterest(added, removed);
        owner.peerInterest(1, added, removed);
        owner.takeInterest(added, removed);
        home.peerInterest(2, added, removed);
    }

    auto alice = new Watcher(1, Position(0, 0, 0));      // simulated at home, about to move
    auto homeWatcher = new Watcher(2, Position(10, 0, 0));
    auto ownerWatcher = new Watcher(3, Position(-10, 0, 0));
    home.add(alice);
    home.add(homeWatcher);
    owner.add(ownerWatcher);
    exchangeInterest();
    assert(owner.isReplica(1) && home.isReplica(3));
    // A guid alice's client has that the owner does not hold yet: an object only home knew of.
    auto known = home.knownTo(1) ~ [ulong(0xF130_0000_0000_0099)];
    foreach (w; [alice, homeWatcher, ownerWatcher])
        w.take();

    home.removeForMigration(alice, 2);
    auto arrived = new Watcher(1, Position(0, 0, 0)); // the same player, now on the owner
    owner.addMigrated(arrived, known);
    foreach (w; [alice, arrived, homeWatcher, ownerWatcher])
        assert(w.take() == [], "nobody's client noticed the handover");
    assert(home.isReplica(1) && home.seesObject(2, 1), "home's player sees alice's replica now");
    assert(!owner.isReplica(1) && owner.seeEachOther(1, 3), "the owner's player sees alice herself now");

    // The object the owner did not hold arrives as a replica a moment later: adopted, not created again.
    import dmangos.world.replication : encodePlayerState;

    owner.replicaCreated(owner: 1, cell: cellKeyAt(10, 0), guid: 0xF130_0000_0000_0099, encodePlayerState(homeWatcher.player, 0));
    assert(arrived.take() == [] && owner.seesObject(1, 0xF130_0000_0000_0099), "the client had it already");
    assert(ownerWatcher.take().length == 1, "the owner's own player had not seen it: it gets its create block");

    // Alice moves on the owner: its player sees it, and home's through the replica.
    arrived.moveTo(5, 0);
    owner.relocated(arrived);
    const ubyte[1] heartbeat = [3];
    owner.sendToWatchers(arrived, Opcode.MSG_MOVE_HEARTBEAT, heartbeat);
    assert(ownerWatcher.take() == [Opcode.MSG_MOVE_HEARTBEAT]);
    assert(homeWatcher.take() == [Opcode.MSG_MOVE_HEARTBEAT] && home.findObject(1).position.x == 5);
}

/// Speech across nodes: a say reaches players in range on other nodes, each node delivering to its own.
unittest
{
    import dmangos.world.replication : Replicator;

    static final class Wire : Replicator
    {
        Map to;
        ushort from;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state) { to.replicaCreated(owner: from, cell: cell, guid: guid, state); }
        void values(ushort, uint, ulong guid, const(ubyte)[] slots) { to.replicaValues(from, guid, slots); }
        void move(ushort, uint, ulong guid, ushort op, const(ubyte)[] b, const(ubyte)[] m) { to.replicaMoved(from, guid, op, b, m); }
        void remove(ushort, uint, ulong guid) { to.replicaRemoved(from, guid); }
        void inRange(ushort, uint, Position c, float r, ushort op, const(ubyte)[] b) { to.deliverInRange(c, r, cast(Opcode) op, b); }
    }
    auto one = new Map(0, MapSettings.init, () => 1000u);
    auto two = new Map(0, MapSettings.init, () => 1000u);
    auto a = new Wire, b = new Wire;
    a.to = two, a.from = 1;
    b.to = one, b.from = 2;
    one.replicator = a;
    two.replicator = b;
    auto alice = new Watcher(1, Position(0, 0, 0));
    auto near = new Watcher(2, Position(20, 0, 0));
    auto far = new Watcher(3, Position(60, 0, 0));
    one.add(alice);
    two.add(near);
    two.add(far);
    ulong[] added, removed;
    two.takeInterest(added, removed);
    one.peerInterest(2, added, removed);
    foreach (w; [alice, near, far])
        w.take();

    const ubyte[1] say = [5];
    one.sendInRange(alice.player.position, 25, Opcode.SMSG_MESSAGECHAT, say);
    assert(alice.take() == [Opcode.SMSG_MESSAGECHAT] && near.take() == [Opcode.SMSG_MESSAGECHAT]);
    assert(far.take() == [], "40 yards beyond a say's range");
}

/**
 * A cell no player has been near for the unload delay unloads with its objects; the
 * cells near a player stay, and so does a cell holding what cannot simply go (a corpse).
 */
unittest
{
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate;
    import dmangos.world.updatefields : TypeId;

    static final class Body : MapObject
    {
        UpdateValues values = UpdateValues(TypeId.corpse);
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return 0xF101_0000_0000_0042; }
        @property Position position() const { return Position(-3000, 0, 0); }
        UpdateData appearance(uint) const { return UpdateData.init; }
    }

    GameObjectTemplate rock = {entry: 7, type: 5, displayId: 1, name: "Rock"};
    MapObject[] spawner(uint, ulong) { return null; }
    auto map = new Map(0, MapSettings(100, 10, 30_000), () => 1000u, &spawner);
    auto alice = new Watcher(1, Position(0, 0, 0));
    map.add(alice);
    const nearSpawn = GameObjectSpawn(1, 7, 0, 10, 0, 0), farSpawn = GameObjectSpawn(2, 7, 0, 3000, 0, 0);
    auto near = new GameObject(nearSpawn, &rock);
    auto far = new GameObject(farSpawn, &rock);
    map.addObject(near);
    map.addObject(far);
    map.addObject(new Body);
    alice.take();

    assert(map.unloadIdleCells(20_000) == 0, "not idle long enough");
    assert(map.unloadIdleCells(10_000) == 1, "the far cell; the corpse's stays");
    assert(map.findObject(far.guid) is null && !map.cellLoaded(cellKeyAt(3000, 0)));
    assert(map.findObject(near.guid) !is null && map.findObject(0xF101_0000_0000_0042) !is null);
    assert(alice.take() == [], "nobody saw it go");
}

/// The timer wheel (docs/DESIGN.md, step 4): an object with nothing to do for a while leaves the tick,
/// comes back when its time is up (or when woken), and its next tick counts all the time it slept.
unittest
{
    import core.time : msecs;
    import dmangos.world.updatefields : TypeId;

    static final class Napper : Moving, Idler
    {
        ulong id;
        Position at;
        int idle;          // what it says after a tick
        int[] ticks;       // the time each tick gave it
        UpdateValues values = UpdateValues(TypeId.unit);
        this(ulong id) { this.id = id; }
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return id; }
        @property Position position() const { return at; }
        UpdateData appearance(uint) const { return UpdateData.init; }
        void tick(MotionWorld, int diff) { ticks ~= diff; }
        @property bool resting() const { return false; }
        @property int idleFor() const { return idle; }
    }

    auto map = new Map(0, MapSettings.init, () => 1000u);
    auto napper = new Napper(0xF130_0000_0000_0042);
    map.addObject(napper);
    assert(map.tickingCount == 1);

    // Busy: it ticks every time.
    map.update(50.msecs);
    map.update(50.msecs);
    assert(napper.ticks == [50, 50] && map.tickingCount == 1);

    // Idle for a second: out of the tick, then back with the whole second (and the tick it woke in).
    napper.idle = 1000;
    map.update(50.msecs);
    assert(map.tickingCount == 0 && map.sleepingCount == 1);
    napper.idle = 0;
    foreach (_; 0 .. 19)
        map.update(50.msecs); // 950 ms: not yet
    assert(napper.ticks.length == 3, "asleep");
    map.update(50.msecs); // 1,000 ms after it fell asleep
    assert(napper.ticks.length == 4 && napper.ticks[3] == 1000, "woken on time, with its sleep");
    assert(map.tickingCount == 1 && map.sleepingCount == 0);

    // Woken early (something gave it something to do): its next tick has the time since it fell asleep.
    napper.idle = 5000;
    map.update(50.msecs);
    napper.idle = 0;
    foreach (_; 0 .. 6)
        map.update(50.msecs);
    map.wake(napper.guid);
    map.update(50.msecs);
    assert(napper.ticks[$ - 1] == 350 && map.sleepingCount == 0, "300 ms asleep and this tick's 50");
    foreach (_; 0 .. 120)
        map.update(50.msecs); // its old wheel entry comes due and is stale: no second waking
    assert(map.tickingCount == 1);

    // Gone while asleep: nothing left behind.
    napper.idle = 2000;
    map.update(50.msecs);
    map.removeObject(napper.guid);
    assert(map.sleepingCount == 0);
    foreach (_; 0 .. 60)
        map.update(50.msecs);
}

/// Only a player's sight loads cells: a creature's or a script's search looks at what is loaded,
/// so searches do not spread loading across the map.
unittest
{
    ulong[] loaded;
    MapObject[] spawner(uint, ulong cell)
    {
        loaded ~= cell;
        return null;
    }

    auto map = new Map(0, MapSettings.init, () => 1000u, &spawner);
    assert(map.objectsNear(Position(0, 0, 0), 1000).length == 0 && loaded.length == 0, "a search loads nothing");
    assert(map.creaturesNear(Position(5000, 5000, 0), 100_000).length == 0 && loaded.length == 0,
        "nor does a huge one (it goes through the cells that hold anything)");
    auto alice = new Watcher(1, Position(0, 0, 0));
    map.add(alice);
    assert(loaded.length > 0 && map.cellLoaded(cellKeyAt(0, 0)), "a player's sight does");
}

/// Changes in the map's tick go out once, at its end; outside it at once.
unittest
{
    import core.time : msecs;
    import dmangos.world.updatefields : TypeId, UNIT_FIELD_HEALTH, UNIT_FIELD_LEVEL;

    static final class Fidget : Moving
    {
        ulong id;
        Position at;
        Map map;
        UpdateValues values = UpdateValues(TypeId.unit);
        this(ulong id) { this.id = id; }
        ref UpdateValues fields() { return values; }
        @property ulong guid() const { return id; }
        @property Position position() const { return at; }
        UpdateData appearance(uint) const
        {
            import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
            import dmangos.world.updatefields : Visibility;

            UpdateData u;
            MovementBlock b;
            b.flags = UpdateFlags.hasPosition;
            u.addCreate(UpdateType.createObject, id, b, values, Visibility.public_);
            return u;
        }
        void tick(MotionWorld, int)
        {
            // Two changes in one tick, each flushed.
            values.set!UNIT_FIELD_HEALTH(values.get!UNIT_FIELD_HEALTH + 1);
            map.flushObjectChanges(this);
            values.set!UNIT_FIELD_LEVEL(values.get!UNIT_FIELD_LEVEL + 1);
            map.flushObjectChanges(this);
        }
        @property bool resting() const { return false; }
    }

    auto map = new Map(0, MapSettings.init, () => 1000u);
    auto alice = new Watcher(1, Position(0, 0, 0));
    map.add(alice);
    auto fidget = new Fidget(0xF130_0000_0000_0077);
    fidget.map = map;
    map.addObject(fidget);
    alice.take();
    map.update(50.msecs);
    assert(alice.take().count(Opcode.SMSG_UPDATE_OBJECT) == 1, "two changes in the tick: one update");
    fidget.values.set!UNIT_FIELD_HEALTH(100u);
    map.flushObjectChanges(fidget);
    assert(alice.take() == [Opcode.SMSG_UPDATE_OBJECT], "outside the tick: at once");
}

// `playerSees`, rule by rule.
unittest
{
    const alive = PlayerView(1, true, false), body_ = PlayerView(2, false, false), ghost = PlayerView(3, false, true);
    PlayerView gm = alive;

    gm.gmTag = true;
    VisibilityFacts f;
    size_t asked;
    VisibilityFacts facts() { ++asked; return f; }

    assert(playerSees(alive, body_, &facts) && playerSees(body_, alive, &facts) && asked == 0, "no ghost: no facts");
    assert(!playerSees(alive, ghost, &facts) && playerSees(gm, ghost, &facts));
    f.sameGroup = true;
    assert(playerSees(alive, ghost, &facts), "its group");
    f = VisibilityFacts.init;
    assert(!playerSees(ghost, ghost, &facts), "a ghost of the other side");
    f.cooperate = true;
    assert(playerSees(ghost, ghost, &facts), "of its own");
    assert(!playerSees(ghost, alive, &facts), "the living far from its corpse");
    f.corpseDistance = 44;
    assert(playerSees(ghost, alive, &facts) && !playerSees(ghost, body_, &facts), "near it: the living, not a body");

    // An invisible game master: its group and tagged game masters see it, nobody else, never a ghost.
    PlayerView hidden = alive;
    hidden.gmInvisible = true;
    f = VisibilityFacts.init;
    assert(!playerSees(alive, hidden, &facts) && playerSees(gm, hidden, &facts));
    f.sameGroup = true;
    assert(playerSees(alive, hidden, &facts) && !playerSees(ghost, hidden, &facts));
    assert(playerSees(hidden, alive, &facts), "it sees everyone");
}

// A creature a script set apart (an escortee on the players' faction) is attacked by the monsters near it that
// would attack a player; creatures as spawned leave each other alone.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f)); // the cells load
    auto map = context.map(0);
    auto escortee = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto monster = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    enum uint players = 1, monsters = 8;
    enum uint escortFaction = 100; // on the players' side
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[escortFaction, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0,
        0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    monster.factionTemplate = context.client.factionTemplates.lookup(14);
    context.data.creatureTemplates.edit(creatureTrainer).faction = 14; // its own: as spawned
    context.data.creatureTemplates.edit(creatureTrainer).detection = 20; // it aggroes as a monster does
    escortee.movement.position = Position(monster.position.x + 3, monster.position.y, monster.position.z);

    void moved()
    {
        now += 2000.msecs;
        map.update(2000.msecs);
        map.objectRelocated(escortee);
    }
    moved();
    assert(monster.ai.currentVictim == 0, "as spawned: no fight");
    escortee.factionTemplate = context.client.factionTemplates.lookup(escortFaction); // a script's escort faction
    moved();
    assert(monster.ai.currentVictim == escortee.guid, "the monster falls on the escorted");
}
