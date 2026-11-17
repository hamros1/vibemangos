/**
 * A map with the players on it, who sees whom, and the packets that follows
 * from that (CMaNGOS `Maps/Map.cpp`, `Grids/`, `Object::UpdateVisibilityOf`).
 *
 * Players are kept in square cells of `cellSize` yards, CMaNGOS's grid cell
 * size, so "who is near" looks at a handful of cells instead of the whole map.
 * Seeing is symmetric: two players see each other when they are within the
 * visibility distance. When that starts, each gets the other's create block;
 * when it ends, an out-of-range block; when one leaves the world, the other
 * gets `SMSG_DESTROY_OBJECT`. Visibility is recomputed when a player has
 * moved `relocationLimit` yards since the last time, as with CMaNGOS's
 * `Visibility.RelocationLowerLimit`.
 *
 * The map knows players through `Inhabitant`, which `WorldSession` implements:
 * the character, and a way to deliver a packet. Tests implement it directly.
 *
 * Creatures and game objects (`MapObject`) are kept in the same cells. A
 * cell's spawns are created when a player first comes near it
 * (`ObjectGridLoader`), through the `Spawner` the map was given, and stay.
 * Players see objects within the visibility distance; the create blocks of
 * everything that came into sight are sent together.
 *
 * Objects that move on their own (`Moving`, creatures) tick with the map:
 * one that moved changes cell, and once it has moved `relocationLimit` yards
 * the players it came near get it and those it left lose it. The map is the
 * `MotionWorld` movement asks for heights and sends its packets through.
 *
 * In a cluster (docs/CLUSTER.md, phase 2) a map holds only what its node owns: a cell's spawns are
 * created only if `owns` says the cell is this node's, an object belongs to the cell it spawned in
 * (its home, until objects migrate in phase 4), and when a region is lost its objects go (`release`)
 * and the players who saw them get an out-of-range block. Standalone, `owns` is null: everything is.
 *
 * Replication (phase 3, `dmangos.world.replication`): the map tells other nodes which cells its
 * players are near (`takeInterest`), sends replicas of its own objects in cells other nodes are
 * interested in (`peerInterest`, through `replicator`), and keeps the replicas other nodes send
 * (`replicaCreated` and the like) with its own objects, where its players see them.
 */
module dmangos.world.map;

import core.time : Duration, MonoTime, msecs, seconds, usecs;
import std.random : Random, unpredictableSeed;

import dmangos.serialization : serialize;
import dmangos.bytes : ByteWriter;
public import dmangos.world.grid : cellSize;
import dmangos.world.grid : cellCoordinate, cellKey, cellKeyAt;
import dmangos.world.creatureai : Combatant, CombatWorld;
import dmangos.world.creature : Creature;
import dmangos.world.gameobject : GameObject, GameObjectWorld;
import dmangos.world.motion : MotionWorld;
import dmangos.world.movement : Position;
import dmangos.world.objects : maxUpdatePacketBytes, seenByEveryone, UpdateData, UpdatePacket, UpdateValues;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ServerDestroyObject;
import dmangos.world.player : DeathState, Player;
import dmangos.world.migration : decodeBundle, encodeBundle, Migrant;
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

/**
 * A map object some of whose fields each viewer sees differently (a creature's tapped and lootable
 * flags: `Object::BuildValuesUpdate`). The map sends the fields as everyone sees them, and to each
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

/// Creates the spawns of one cell of a map: called once per cell, when a player first comes near.
alias Spawner = MapObject[] delegate(uint map, ulong cell);

/// The most create blocks in one update packet, so that a crowded place does not make one huge packet.
private enum maxBlocksPerPacket = 40;

/// Distances that decide who sees and hears whom (`mangosd.conf`'s `Visibility.*`, `ListenRange.*`).
struct MapSettings
{
    float visibilityDistance = 100; /// `Visibility.Distance.Continents`
    float relocationLimit = 10;     /// `Visibility.RelocationLowerLimit`
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

/// See the module documentation.
final class Map : CombatWorld, GameObjectWorld
{
    immutable uint id;

    private
    {
        MapSettings settings;
        uint delegate() serverTime;
        Inhabitant[ulong] members;      // by player guid
        bool[ulong][ulong] cells;       // cell key -> guids in it
        ulong[ulong] cellOf;            // guid -> cell key
        bool[ulong][ulong] sees;        // guid -> guids it sees (and that see it)
        Position[ulong] visibilityAt;   // where visibility was last computed

        Spawner spawner;
        MapObject[ulong] objects;       // creatures and game objects, by guid
        bool[ulong][ulong] objectCells; // cell key -> object guids in it
        bool[ulong] loadedCells;        // cells whose spawns exist
        bool[ulong][ulong] seesObjects; // player guid -> object guids its client has

        Terrain terrain;                // heights for movement; none in tests
        Random rng;
        Moving[ulong] movers;           // the objects that can move, resting or not
        Moving[] ticking;               // those that are not resting: the tick goes through these
        size_t[ulong] tickingAt;        // guid -> its place in `ticking`
        ulong[ulong] objectCellOf;      // mover guid -> its cell key
        ulong[ulong] homeCellOf;        // object guid -> the cell it spawned in
        bool delegate(ulong cell) owns; // whether this node owns a cell; null: every cell

        // Replication (phase 3).
        bool[ushort][ulong] peerCells;     // cell key -> peers that want what this node simulates there
        bool[ushort][ulong] replicatedTo;  // own object guid -> peers holding a replica of it
        bool[ulong] replicas;              // guids of replicas (another node simulates them)
        uint[ulong] localInterest;         // cell key -> local players near it
        bool[ulong][ulong] interestOf;     // local player guid -> the cells near it
        bool[ulong] interestAdded, interestRemoved; // changes since `takeInterest`

        // Players arriving from another node (phase 4b): guids their client has that this map does not
        // hold yet; adopted without a create block when they come, forgotten after `lingerFor`.
        bool[ulong][ulong] lingering;    // player guid -> guids
        MonoTime[ulong] lingerUntil;
        Position[ulong] objectVisibilityAt; // where a mover's visibility was last computed
        Duration unticked;              // time not yet given to the movers (under a millisecond)
    }

    invariant (members.length == cellOf.length && members.length == sees.length
        && members.length == seesObjects.length);

    ///
    this(uint id, MapSettings settings, uint delegate() serverTime, Spawner spawner = null, Terrain terrain = null,
        bool delegate(ulong cell) owns = null)
    in (serverTime !is null)
    {
        this.owns = owns;
        this.id = id;
        this.settings = settings;
        this.serverTime = serverTime;
        this.spawner = spawner;
        this.terrain = terrain;
        rng = Random(unpredictableSeed);
    }

    /// Sends replicas of this map's own objects to other nodes; null when standalone.
    Replicator replicator;

    /// Number of creatures and game objects created so far.
    @property size_t objectCount() const
    {
        return objects.length;
    }

    /// The creature or game object with this guid, if its cell is loaded; null otherwise.
    MapObject findObject(ulong guid)
    {
        return objects.get(guid, null);
    }

    /// Sends what changed in an object's fields to the players whose clients have it, then forgets the changes.
    void flushObjectChanges(MapObject object)
    {
        if (replicator !is null && object.guid !in replicas)
            if (auto peers = object.guid in replicatedTo)
            {
                const slots = object.fields.changedPublicSlots;
                if (slots.length)
                {
                    const bytes = encodeSlots(slots);
                    foreach (peer, _; *peers)
                        replicator.values(peer, id, object.guid, bytes);
                }
            }
        if (object.fields.hasChangesFor(seenByEveryone))
        {
            auto personal = cast(PerViewer) object;
            UpdateData update;
            update.addValues(object.guid, object.fields, seenByEveryone);
            foreach (guid, seen; seesObjects)
                if (object.guid in seen)
                {
                    if (personal !is null && personal.personalized)
                    {
                        auto view = ViewerAdjust(personal, guid, groupOf is null ? 0 : groupOf(guid));
                        UpdateData own;
                        own.addValues(object.guid, object.fields, seenByEveryone, &view.adjust);
                        deliverUpdate(members[guid], own);
                    }
                    else
                        deliverUpdate(members[guid], update);
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
        auto personal = cast(PerViewer) object;
        if (personal is null)
            return;
        foreach (guid, seen; seesObjects)
            if (object.guid in seen)
                personalize(members[guid], object, true);
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
        if (auto holders = who.character.guid in replicatedTo)
            if ((*holders).length)
            {
                const slots = who.character.changedStrangerSlots;
                if (slots.length == 0)
                    return;
                const bytes = encodeSlots(slots);
                foreach (peer, _; *holders)
                    replicator.values(peer, id, who.character.guid, bytes);
            }
    }

    /// Whether the player's client has the object.
    bool seesObject(ulong player, ulong object) const
    {
        if (const seen = player in seesObjects)
            return (object in *seen) !is null;
        return false;
    }

    /// The creatures and game objects within `range` yards of `center`, loading their cells if needed.
    MapObject[] objectsNear(Position center, float range)
    {
        MapObject[] found;
        foreach (key; cellKeysNear(center, range))
        {
            loadCell(key);
            if (const cell = key in objectCells)
                foreach (guid, _; *cell)
                {
                    auto object = objects[guid];
                    if (distanceSquared(center, object.position) <= range ^^ 2)
                        found ~= object;
                }
        }
        return found;
    }

    /// `ObjectGridLoader::Load` for one cell: its spawns, once.
    private void loadCell(ulong key)
    {
        if (spawner is null || key in loadedCells || (owns !is null && !owns(key)))
            return;
        loadedCells[key] = true;
        foreach (object; spawner(id, key))
            hold(object, key);
    }

    /// Takes in an object whose home is cell `key`.
    private void hold(MapObject object, ulong key)
    {
        if (object.guid in replicas)
            dropReplica(object.guid); // this node owns it now (phase 3); its viewers keep seeing it
        objects[object.guid] = object;
        objectCells[key][object.guid] = true;
        homeCellOf[object.guid] = key;
        if (auto mover = cast(Moving) object)
        {
            movers[object.guid] = mover;
            startTicking(mover);
            objectCellOf[object.guid] = key;
            objectVisibilityAt[object.guid] = object.position;
        }
        replicate(object, key);
    }

    /**
     * Puts an object on the map that no cell spawned (a corpse, a creature respawned), and shows it to
     * the players who see where it is.
     */
    void addObject(MapObject object)
    {
        const key = cellKeyAt(object.position.x, object.position.y);
        loadCell(key);
        if (object.guid in objects)
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
        if (who.character.guid in members)
            updateVisibility(who);
    }

    /// Takes an object off the map (a corpse gone, a creature despawned); those who saw it are told.
    void removeObject(ulong guid)
    {
        if (guid in objects)
            forget([guid]);
    }

    /**
     * Whether `who` can see `object` at all, wherever they are: a spirit healer only shows itself to the
     * dead (CMaNGOS gives it the ghost aura).
     */
    bool objectVisibleTo(const MapObject object, const Inhabitant who) const
    {
        enum uint spiritHealer = 0x20, spiritGuide = 0x40; // UNIT_NPC_FLAG_SPIRITHEALER, _SPIRITGUIDE
        if (auto creature = cast(const Creature) object)
            if (creature.template_.npcFlags & (spiritHealer | spiritGuide))
                return who.character.deathState != DeathState.alive;
        return true;
    }

    /// One tick of the world update (`Map::Update`): every object that moves on its own, then where it got to.
    void update(Duration elapsed)
    {
        unticked += elapsed;
        const diff = cast(int) unticked.total!"msecs";
        if (diff <= 0)
            return;
        unticked -= diff.msecs;
        Moving[] restingNow;
        foreach (mover; ticking)
        {
            const before = mover.position;
            mover.tick(this, diff);
            if (mover.position != before)
                objectRelocated(mover);
            if (mover.resting)
                restingNow ~= mover;
        }
        foreach (mover; restingNow)
            stopTicking(mover.guid);
        expireLingering();
    }

    // -----------------------------------------------------------------------
    // Players moving between nodes (phase 4b)
    // -----------------------------------------------------------------------

    /// How long a guid an arriving player's client has may wait for this map to hold it.
    enum Duration lingerFor = 5.seconds;

    /// Every guid the player's client has from this map: objects and players.
    ulong[] knownTo(ulong guid)
    {
        ulong[] known;
        if (auto objects = guid in seesObjects)
            known ~= (*objects).keys;
        if (auto players = guid in sees)
            known ~= (*players).keys;
        return known;
    }

    /**
     * A player's simulation leaves for node `next`: it goes without a destroy packet, and players here
     * who saw it go on seeing a replica of it (the next node's replica replaces it).
     */
    void removeForMigration(Inhabitant who, ushort next)
    {
        const guid = who.character.guid;
        auto placeholder = new Replica(guid, next, encodePlayerState(who.character, serverTime()));
        const watchers = sees[guid].keys;
        foreach (other; watchers)
        {
            sees[other].remove(guid);
            seesObjects[other][guid] = true;
        }
        if (auto cells = guid in interestOf)
        {
            foreach (cell, _; *cells)
                dropInterest(cell);
            interestOf.remove(guid);
        }
        replicatedTo.remove(guid); // the next node's replica replaces those elsewhere
        cells[cellOf[guid]].remove(guid);
        cellOf.remove(guid);
        sees.remove(guid);
        seesObjects.remove(guid);
        visibilityAt.remove(guid);
        lingering.remove(guid);
        lingerUntil.remove(guid);
        members.remove(guid);
        if (watchers.length)
        {
            objects[guid] = placeholder;
            replicas[guid] = true;
            movers[guid] = placeholder;
            const at = cellKeyAt(placeholder.position.x, placeholder.position.y);
            objectCells[at][guid] = true;
            objectCellOf[guid] = at;
            objectVisibilityAt[guid] = placeholder.position;
        }
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

        // Its replica here, if any: those who saw it see the real one now.
        bool[ulong] sawReplica;
        if (guid in replicas)
        {
            foreach (player, ref seen; seesObjects)
                if (seen.remove(guid))
                    sawReplica[player] = true;
            dropReplica(guid);
        }

        members[guid] = who;
        sees[guid] = null;
        seesObjects[guid] = null;
        place(guid, who.character.position);
        visibilityAt[guid] = who.character.position;
        if (replicator !is null)
            updateInterest(guid, who.character.position);
        const time = serverTime();

        // Players in sight: each pair gets what it does not have.
        bool[ulong] inSight;
        UpdateData received;
        MapObject[] personalAfter; // shown with a view of their own, after their create blocks
        foreach (other; near(who.character.position, settings.visibilityDistance))
        {
            const o = other.character.guid;
            if (o == guid)
                continue;
            inSight[o] = true;
            sees[guid][o] = true;
            sees[o][guid] = true;
            if (o !in knows)
                received.append(other.appearanceFor(who, time));
            if (o !in sawReplica)
                deliverUpdate(other, who.appearanceFor(other, time));
        }
        foreach (player, _; sawReplica)
            if (player !in inSight)
            {
                UpdateData forget;
                forget.addOutOfRange([guid]);
                deliverUpdate(members[player], forget);
            }

        // Objects in sight.
        foreach (object; objectsNear(who.character.position, settings.visibilityDistance))
        {
            if (!objectVisibleTo(object, who))
                continue;
            inSight[object.guid] = true;
            seesObjects[guid][object.guid] = true;
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
            if (k in inSight || k == guid)
                continue;
            if (k in objects || k in members)
                gone ~= k;
            else
                lingering[guid][k] = true;
        }
        if (gone.length)
        {
            UpdateData forget;
            forget.addOutOfRange(gone);
            deliverUpdate(who, forget);
        }
        if (auto l = guid in lingering)
            lingerUntil[guid] = MonoTime.currTime + lingerFor;
        replicatePlayer(who);
    }

    /// Whether `object` lingered for `player` (its client has it): now it is simply seen.
    private bool adoptLingering(ulong player, ulong object)
    {
        if (auto l = player in lingering)
            return (*l).remove(object);
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
                if (auto l = player in lingering)
                    if ((*l).length && player in members)
                    {
                        UpdateData forget;
                        forget.addOutOfRange((*l).keys);
                        deliverUpdate(members[player], forget);
                    }
            }
        foreach (player; done)
        {
            lingering.remove(player);
            lingerUntil.remove(player);
        }
    }

    /// Puts a resting object back in the tick: something gave it something to do.
    void wake(ulong guid)
    {
        if (auto mover = guid in movers)
            startTicking(*mover);
    }

    /**
     * What each cell holds, weighed for how much of the loop it takes (phase 6): an object in the tick
     * `ticking`, a resting one `resting`, a player simulated here `player`. Replicas count for nothing
     * here: the node that simulates them weighs them.
     */
    void weighCells(uint ticking, uint resting, uint player, scope void delegate(ulong cell, ulong weight) sink)
    {
        ulong[ulong] weights;
        foreach (guid, object; objects)
        {
            if (guid in replicas)
                continue;
            const cell = objectCellOf.get(guid, homeCellOf.get(guid, ulong.max));
            if (cell == ulong.max)
                continue;
            weights[cell] = weights.get(cell, 0) + (guid in tickingAt ? ticking : resting);
        }
        foreach (guid, cell; cellOf)
            weights[cell] = weights.get(cell, 0) + player;
        foreach (cell, weight; weights)
            sink(cell, weight);
    }

    /// Objects in the tick now (not resting).
    @property size_t tickingCount() const
    {
        return ticking.length;
    }

    /// `Map::CreatureRelocation`: an object moved; its cell follows, and who sees it once it has gone far enough.
    void objectRelocated(MapObject object)
    {
        const guid = object.guid;
        const position = object.position;
        if (auto creature = cast(Creature) object)
            creatureNoticing(creature);
        const key = cellKeyAt(position.x, position.y);
        if (auto old = guid in objectCellOf)
            if (*old != key)
            {
                objectCells[*old].remove(guid);
                objectCells[key][guid] = true;
                *old = key;
                replicate(object, key);
            }
        const last = objectVisibilityAt.get(guid, position);
        if (distanceSquared(last, position) < settings.relocationLimit ^^ 2)
            return;
        objectVisibilityAt[guid] = position;
        updateObjectVisibility(object);
    }

    /**
     * A region was lost (`inside` says which cells): the objects that spawned there go, the players
     * who saw them are told they are out of range, and the cells may load again if regained.
     */
    void release(scope bool delegate(ulong cell) inside)
    {
        ulong[] gone;
        foreach (guid, home; homeCellOf)
            if (inside(home))
                gone ~= guid;
        forget(gone);
        ulong[] unloaded;
        foreach (cell, _; loadedCells)
            if (inside(cell))
                unloaded ~= cell;
        foreach (cell; unloaded)
            loadedCells.remove(cell);
    }

    /**
     * A region leaves for node `next` with its objects (phase 4; `inside` says which cells are it):
     * each object homed there is written out by `save`, and stays here as a replica of `next`'s object,
     * so nobody who sees it notices; peers holding replicas of it will get `next`'s. Returns the bundle
     * (`dmangos.world.migration`) for `next`.
     */
    const(ubyte)[] migrateOut(scope bool delegate(ulong cell) inside, ushort next,
        scope Migrant delegate(MapObject) save)
    {
        Migrant[] migrants;
        foreach (guid, home; homeCellOf.dup)
        {
            if (!inside(home))
                continue;
            auto object = objects[guid];
            auto migrant = save(object);
            migrant.home = home;
            migrants ~= migrant;
            homeCellOf.remove(guid);
            replicatedTo.remove(guid);
            if (auto source = cast(Replicable) object)
            {
                auto replica = new Replica(guid, next, encodeState(source, serverTime()));
                objects[guid] = replica;
                replicas[guid] = true;
                stopTicking(guid);
                movers[guid] = replica;
                objectCellOf[guid] = objectCellOf.get(guid, home);
                objectVisibilityAt[guid] = replica.position;
                startTicking(replica);
            }
        }
        ulong[] cells;
        foreach (cell, _; loadedCells)
            if (inside(cell))
                cells ~= cell;
        foreach (cell; cells)
            loadedCells.remove(cell);
        return encodeBundle(cells, migrants);
    }

    /**
     * A region arrives with its objects from its last owner (phase 4): `restore` rebuilds each, which
     * replaces any replica of it (its viewers keep seeing it), and the cells it had loaded count as
     * loaded here.
     */
    void migrateIn(const(ubyte)[] bundle, scope MapObject delegate(const ref Migrant) restore)
    {
        ulong[] cells;
        Migrant[] migrants;
        decodeBundle(bundle, cells, migrants);
        foreach (cell; cells)
            loadedCells[cell] = true;
        foreach (ref m; migrants)
        {
            auto object = restore(m);
            if (object is null)
                continue;
            const guid = object.guid;
            if (guid in replicas)
                dropReplica(guid);
            else if (guid in objects)
            {
                // Spawned afresh here a moment ago (a gained cell loaded before its bundle was applied): the
                // migrant is the newer state. Its viewers see it go and come back as it really is.
                import dmangos.log : warning;

                warning!"migration: object %016X was spawned here afresh; the migrated one replaces it"(guid);
                forget([guid]);
            }
            const at = cellKeyAt(object.position.x, object.position.y);
            objects[guid] = object;
            objectCells[at][guid] = true;
            homeCellOf[guid] = m.home;
            if (auto mover = cast(Moving) object)
            {
                movers[guid] = mover;
                objectCellOf[guid] = at;
                objectVisibilityAt[guid] = object.position;
                startTicking(mover);
            }
            replicate(object, at);
            updateObjectVisibility(object);
        }
    }

    /// Cells were gained: every player looks around again, so those near them load, and so do cells other nodes want.
    void ownershipGained()
    {
        foreach (who; members)
            updateVisibility(who);
        foreach (cell, _; peerCells)
            loadCell(cell);
    }

    // -----------------------------------------------------------------------
    // Replication (phase 3)
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
            if (const inCell = cell in objectCells)
                foreach (guid, _; *inCell)
                    if (auto holders = guid in replicatedTo)
                        if ((*holders).remove(peer))
                            replicator.remove(peer, id, guid);
            if (const players = cell in cells)
                foreach (guid, _; *players)
                    if (auto holders = guid in replicatedTo)
                        if ((*holders).remove(peer))
                            replicator.remove(peer, id, guid);
        }
        foreach (cell; added)
        {
            peerCells[cell][peer] = true;
            loadCell(cell); // replicates what it spawns
            if (const inCell = cell in objectCells)
                foreach (guid, _; *inCell)
                    replicate(objects[guid], cell);
            if (const players = cell in cells)
                foreach (guid, _; *players)
                    replicatePlayer(members[guid]);
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
        foreach (guid, ref peers; replicatedTo)
            peers.remove(peer);
        ulong[] gone;
        foreach (guid, _; replicas)
            if ((cast(Replica) objects[guid]).owner == peer)
                gone ~= guid;
        forget(gone);
    }

    /// A replica of `guid`, simulated by node `owner`, in `cell` (`encodeState`).
    void replicaCreated(ushort owner, ulong cell, ulong guid, const(ubyte)[] state)
    {
        if (guid in objects)
        {
            if (guid !in replicas)
                return; // this node simulates it now: the message is from before the change
            dropReplica(guid);
        }
        auto replica = new Replica(guid, owner, state);
        objects[guid] = replica;
        replicas[guid] = true;
        movers[guid] = replica;
        startTicking(replica);
        const at = cellKeyAt(replica.position.x, replica.position.y);
        objectCells[at][guid] = true;
        objectCellOf[guid] = at;
        objectVisibilityAt[guid] = replica.position;
        updateObjectVisibility(replica);
    }

    /// Fields of a replica changed on its owner.
    void replicaValues(ushort owner, ulong guid, const(ubyte)[] slots)
    {
        if (auto replica = replicaFrom(owner, guid))
        {
            replica.applySlots(slots);
            flushObjectChanges(replica);
        }
    }

    /// A replica started or stopped a walk: its players get the packet the owner's players got.
    void replicaMoved(ushort owner, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
    {
        if (auto replica = replicaFrom(owner, guid))
        {
            replica.applyMotion(motion);
            startTicking(replica);
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

    /// The cells this map's players became near and stopped being near since the last call.
    void takeInterest(out ulong[] added, out ulong[] removed)
    {
        foreach (cell, _; interestAdded)
            added ~= cell;
        foreach (cell, _; interestRemoved)
            removed ~= cell;
        interestAdded = null;
        interestRemoved = null;
    }

    /// Every cell this map's players are near, for a node that just linked.
    ulong[] interestCells() const
    {
        return localInterest.keys;
    }

    /// Replicas of other nodes' objects on this map.
    @property size_t replicaCount() const
    {
        return replicas.length;
    }

    /// Whether `guid` is a replica here.
    bool isReplica(ulong guid) const
    {
        return (guid in replicas) !is null;
    }

    /// See `MotionWorld.groundHeight`.
    float groundHeight(float x, float y, float z, bool swim)
    {
        if (terrain is null)
            return invalidHeightValue;
        return terrain.heightStatic(x, y, z, true, swim ? defaultWaterSearch : defaultHeightSearch);
    }

    /// See `MotionWorld.waterOrGroundLevel`.
    float waterOrGroundLevel(float x, float y, float z, float groundZ, float minWaterDeep)
    {
        if (terrain is null || terrain.tile(x, y) is null)
            return invalidHeightValue;
        enum ubyte allLiquids = 0x0F; // MAP_ALL_LIQUIDS
        LiquidData liquid;
        if (terrain.liquidStatus(x, y, groundZ, allLiquids, liquid) == LiquidStatus.noWater)
            return groundZ;
        // Deep enough to swim: just under the surface; shallow: on the ground.
        return liquid.level - groundZ > minWaterDeep ? liquid.level - minWaterDeep : groundZ;
    }

    /// See `MotionWorld.sendToObservers`.
    void sendToObservers(ulong guid, Opcode opcode, const(ubyte)[] body_)
    {
        if (replicator !is null && guid !in replicas)
            if (auto peers = guid in replicatedTo)
                if (auto object = cast(Replicable) objects.get(guid, null))
                {
                    const motion = encodeMotion(object.motion(serverTime()));
                    foreach (peer, _; *peers)
                        replicator.move(peer, id, guid, cast(ushort) opcode, body_, motion);
                }
        foreach (player, seen; seesObjects)
            if (guid in seen)
                members[player].deliver(opcode, body_);
    }

    /// See `CombatWorld.combatant`.
    Combatant combatant(ulong guid)
    {
        return cast(Combatant) members.get(guid, null);
    }

    /// See `CombatWorld.inLineOfSight`: at eye height, through the vmaps; anything goes without terrain.
    bool inLineOfSight(Position a, Position b)
    {
        enum eyes = 2.0f;
        return terrain is null || terrain.isInLineOfSight(a.x, a.y, a.z + eyes, b.x, b.y, b.z + eyes);
    }

    /// See `CombatWorld.creaturesNear`.
    Creature[] creaturesNear(Position center, float range)
    {
        Creature[] found;
        foreach (object; objectsNear(center, range))
            if (auto creature = cast(Creature) object)
                found ~= creature;
        return found;
    }

    /// See `CombatWorld.creatureAt`.
    Creature creatureAt(ulong guid)
    {
        return cast(Creature) objects.get(guid, null);
    }

    /// See `CombatWorld.combatantsNear`.
    Combatant[] combatantsNear(Position center, float range)
    {
        Combatant[] found;
        foreach (inhabitant; near(center, range))
            if (auto c = cast(Combatant) inhabitant)
                found ~= c;
        return found;
    }

    /// Told when a creature's corpse goes (`RemoveCorpse`), to bring it back later; null: never comes back.
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

    /// `MoveInLineOfSight` for the creatures a player sees, when it has moved.
    private void playerNoticed(Inhabitant who)
    {
        auto combatant = cast(Combatant) who;
        if (combatant is null)
            return;
        const at = who.character.position;
        if (auto seen = who.character.guid in seesObjects)
            foreach (guid, _; *seen)
                if (auto creature = cast(Creature) objects.get(guid, null))
                    if (creature.ai !is null && creature.ai.mayNotice
                        && distanceSquared(creature.position, at) < noticeDistance ^^ 2)
                        creature.ai.moveInLineOfSight(combatant, this);
    }

    /// `MoveInLineOfSight` for the players who see a creature, when it has moved.
    private void creatureNoticing(Creature creature)
    {
        if (creature.ai is null || creature.ai.inCombat || creature.ai.evading || !creature.ai.mayNotice)
            return;
        // The players near it (by cell), of those that see it.
        foreach (who; near(creature.position, noticeDistance))
            if (auto seen = who.character.guid in seesObjects)
                if (creature.guid in *seen)
                    if (auto combatant = cast(Combatant) who)
                        creature.ai.moveInLineOfSight(combatant, this);
    }

    /// See `MotionWorld.random`.
    ref Random random()
    {
        return rng;
    }

    /// Number of players on the map.
    @property size_t population() const
    {
        return members.length;
    }

    /// Whether the players with guids `a` and `b` see each other.
    bool seeEachOther(ulong a, ulong b) const
    {
        if (const seen = a in sees)
            return (b in *seen) !is null;
        return false;
    }

    /// The player with `guid` on this map, or null.
    Inhabitant find(ulong guid)
    {
        return members.get(guid, null);
    }

    /// `Map::Add`: puts a player on the map, and introduces it to everyone in sight.
    void add(Inhabitant who)
    in (who.character.guid !in members, "a player is on a map once")
    {
        const guid = who.character.guid;
        members[guid] = who;
        sees[guid] = null;
        seesObjects[guid] = null;
        place(guid, who.character.position);
        updateVisibility(who);
        replicatePlayer(who);
    }

    /// `Map::Remove`: takes a player off the map; those who saw it are told to destroy it.
    void remove(Inhabitant who)
    in (who.character.guid in members, "only a player on the map can leave it")
    {
        const guid = who.character.guid;
        if (auto cells = guid in interestOf)
        {
            foreach (cell, _; *cells)
                dropInterest(cell);
            interestOf.remove(guid);
        }
        if (auto holders = guid in replicatedTo)
        {
            foreach (peer, _; *holders)
                replicator.remove(peer, id, guid);
            replicatedTo.remove(guid);
        }
        foreach (other, _; sees[guid])
        {
            sees[other].remove(guid);
            deliverPacket(members[other], ServerDestroyObject(guid));
        }
        cells[cellOf[guid]].remove(guid);
        cellOf.remove(guid);
        sees.remove(guid);
        seesObjects.remove(guid);
        visibilityAt.remove(guid);
        members.remove(guid);
    }

    /// `Map::PlayerRelocation`: after a player moved. Updates its cell, and visibility if it moved far enough.
    void relocated(Inhabitant who)
    in (who.character.guid in members)
    {
        const guid = who.character.guid;
        const position = who.character.position;
        if (place(guid, position))
            replicatePlayer(who);
        if (distanceSquared(visibilityAt[guid], position) >= settings.relocationLimit ^^ 2)
            updateVisibility(who);
        playerNoticed(who);
    }

    /// Delivers a packet to every player that sees `from`, and to `from` itself if `includeSelf`.
    void sendToWatchers(Inhabitant from, Opcode opcode, const(ubyte)[] body_, bool includeSelf = false)
    {
        if (auto holders = from.character.guid in replicatedTo)
            if ((*holders).length)
            {
                const motion = encodeMotion(from.character.motionForOthers(serverTime()));
                foreach (peer, _; *holders)
                    replicator.move(peer, id, from.character.guid, cast(ushort) opcode, body_, motion);
            }
        if (includeSelf)
            from.deliver(opcode, body_);
        foreach (other, _; sees[from.character.guid])
            members[other].deliver(opcode, body_);
    }

    /// The players that see `from`.
    Inhabitant[] watchers(const Inhabitant from)
    {
        Inhabitant[] found;
        if (auto seen = from.character.guid in sees)
            foreach (other, _; *seen)
                found ~= members[other];
        return found;
    }

    /**
     * Delivers a packet to every player within `range` yards of `center`, whether they see each other or
     * not, on this node and on every other with players near (phase 5).
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

    /// The players within `range` yards of `center`.
    Inhabitant[] near(Position center, float range)
    {
        Inhabitant[] found;
        foreach (key; cellKeysNear(center, range))
            if (const cell = key in cells)
                foreach (guid, _; *cell)
                {
                    auto who = members[guid];
                    if (distanceSquared(center, who.character.position) <= range ^^ 2)
                        found ~= who;
                }
        return found;
    }

private:
    void startTicking(Moving mover)
    {
        if (mover.guid in tickingAt)
            return;
        tickingAt[mover.guid] = ticking.length;
        ticking ~= mover;
    }

    void stopTicking(ulong guid)
    {
        if (auto at = guid in tickingAt)
        {
            const i = *at;
            auto last = ticking[$ - 1];
            ticking[i] = last;
            tickingAt[last.guid] = i;
            ticking.length -= 1;
            ticking.assumeSafeAppend();
            tickingAt.remove(guid);
        }
    }

    /// Replicas of an own object for every peer that wants its cell and has none; removals for those that do not.
    void replicate(MapObject object, ulong cell)
    {
        if (replicator is null || object.guid in replicas)
            return;
        auto source = cast(Replicable) object;
        if (source is null)
            return;
        replicateGuid(object.guid, cell, () => encodeState(source, serverTime()));
    }

    /// A local player, as `replicate` for objects: a replica on every node that wants its cell (phase 3b).
    void replicatePlayer(Inhabitant who)
    {
        if (replicator is null)
            return;
        const guid = who.character.guid;
        replicateGuid(guid, cellOf[guid], () => encodePlayerState(who.character, serverTime()));
    }

    /// Replicas of `guid` for the peers that want `cell`, and removals for the others.
    void replicateGuid(ulong guid, ulong cell, scope const(ubyte)[] delegate() makeState)
    {
        auto wanted = cell in peerCells;
        if (auto holders = guid in replicatedTo)
        {
            ushort[] leaving;
            foreach (peer, _; *holders)
                if (wanted is null || peer !in *wanted)
                    leaving ~= peer;
            foreach (peer; leaving)
            {
                (*holders).remove(peer);
                replicator.remove(peer, id, guid);
            }
        }
        if (wanted is null)
            return;
        const(ubyte)[] state;
        foreach (peer, _; *wanted)
            if (peer !in replicatedTo.require(guid, null))
            {
                if (state is null)
                    state = makeState();
                replicatedTo[guid][peer] = true;
                replicator.create(peer, id, cell, guid, state);
            }
    }

    /// Objects go: the players who saw them are told, peers holding replicas of them too.
    void forget(const(ulong)[] gone)
    {
        foreach (player, ref seen; seesObjects)
        {
            ulong[] forgotten;
            foreach (guid; gone)
                if (seen.remove(guid))
                    forgotten ~= guid;
            if (forgotten.length)
            {
                UpdateData forget;
                forget.addOutOfRange(forgotten);
                deliverUpdate(members[player], forget);
            }
        }
        foreach (guid; gone)
        {
            if (auto holders = guid in replicatedTo)
                foreach (peer, _; *holders)
                    replicator.remove(peer, id, guid);
            replicatedTo.remove(guid);
            const cell = objectCellOf.get(guid, homeCellOf.get(guid, ulong.max));
            if (auto inCell = cell in objectCells)
                (*inCell).remove(guid);
            objects.remove(guid);
            movers.remove(guid);
        stopTicking(guid);
            stopTicking(guid);
            objectCellOf.remove(guid);
            objectVisibilityAt.remove(guid);
            homeCellOf.remove(guid);
            replicas.remove(guid);
        }
    }

    /// Takes a replica out without telling anyone (a real object with its guid replaces it).
    void dropReplica(ulong guid)
    {
        if (auto at = guid in objectCellOf)
            if (auto inCell = *at in objectCells)
                (*inCell).remove(guid);
        objects.remove(guid);
        movers.remove(guid);
        stopTicking(guid);
        objectCellOf.remove(guid);
        objectVisibilityAt.remove(guid);
        replicas.remove(guid);
    }

    /// The replica `guid`, if `owner` sends it.
    Replica replicaFrom(ushort owner, ulong guid)
    {
        if (guid !in replicas)
            return null;
        auto replica = cast(Replica) objects[guid];
        return replica.owner == owner ? replica : null;
    }

    /// The cells a local player is near now; the map's interest follows (phase 3).
    void updateInterest(ulong guid, Position position)
    {
        bool[ulong] near;
        foreach (cell; cellKeysNear(position, settings.visibilityDistance))
            near[cell] = true;
        auto had = guid in interestOf;
        foreach (cell, _; near)
            if (had is null || cell !in *had)
                if (localInterest.require(cell, 0)++ == 0)
                {
                    if (!interestRemoved.remove(cell))
                        interestAdded[cell] = true;
                }
        if (had !is null)
            foreach (cell, _; *had)
                if (cell !in near)
                    dropInterest(cell);
        interestOf[guid] = near;
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
    bool place(ulong guid, Position position)
    {
        const key = cellKeyAt(position.x, position.y);
        if (const old = guid in cellOf)
        {
            if (*old == key)
                return false;
            cells[*old].remove(guid);
        }
        cells[key][guid] = true;
        cellOf[guid] = key;
        return true;
    }

    /// `Player::UpdateVisibilityOf` for every player near `who`, both ways.
    void updateVisibility(Inhabitant who)
    {
        const guid = who.character.guid;
        visibilityAt[guid] = who.character.position;
        if (replicator !is null) // only other nodes need to know where this map's players are
            updateInterest(guid, who.character.position);

        bool[ulong] inSight;
        foreach (other; near(who.character.position, settings.visibilityDistance))
            if (other.character.guid != guid)
                inSight[other.character.guid] = true;

        // Newly in sight: each gets the other's create block. `who` gets theirs a packet's worth at a time;
        // they get `who`'s, built and compressed once for each kind of viewer (a crowd is one kind).
        const time = serverTime();
        UpdateData received;
        UpdatePacket[uint] shown;
        foreach (other, _; inSight)
            if (other !in sees[guid])
            {
                sees[guid][other] = true;
                sees[other][guid] = true;
                auto viewer = members[other];
                const block = viewer.appearanceFor(who, time);
                if (!received.empty && received.byteSize + block.byteSize > maxUpdatePacketBytes)
                {
                    deliverUpdate(who, received);
                    received = UpdateData.init;
                }
                received.append(block);
                const kind = who.appearanceKind(viewer);
                auto packet = kind in shown;
                if (packet is null)
                    packet = &(shown[kind] = who.appearanceFor(viewer, time).build());
                deliverBuilt(viewer, *packet);
            }
        if (!received.empty)
            deliverUpdate(who, received);

        // Out of sight: both forget, `who` in one block for everyone it lost.
        ulong[] gone;
        foreach (other, _; sees[guid])
            if (other !in inSight)
                gone ~= other;
        foreach (other; gone)
        {
            sees[guid].remove(other);
            sees[other].remove(guid);
            UpdateData forget;
            forget.addOutOfRange([guid]);
            deliverUpdate(members[other], forget);
        }

        // Creatures and game objects: those that came into sight, in packets of a few dozen, and those that left.
        bool[ulong] objectsInSight;
        UpdateData created;
        MapObject[] personalAfter; // shown with a view of their own, after their create blocks
        foreach (object; objectsNear(who.character.position, settings.visibilityDistance))
        {
            if (!objectVisibleTo(object, who))
                continue;
            objectsInSight[object.guid] = true;
            if (object.guid in seesObjects[guid])
                continue;
            seesObjects[guid][object.guid] = true;
            if (adoptLingering(guid, object.guid))
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
        foreach (object, _; seesObjects[guid])
            if (object !in objectsInSight)
                gone ~= object;
        foreach (object; gone)
            seesObjects[guid].remove(object);

        if (gone.length == 0)
            return;
        UpdateData forgetAll;
        forgetAll.addOutOfRange(gone);
        deliverUpdate(who, forgetAll);
    }

    /// An object moved: players it came near get it, those it left lose it.
    void updateObjectVisibility(MapObject object)
    {
        const guid = object.guid;
        foreach (who; near(object.position, settings.visibilityDistance))
        {
            auto seen = &seesObjects[who.character.guid];
            if (guid in *seen || !objectVisibleTo(object, who))
                continue;
            (*seen)[guid] = true;
            if (adoptLingering(who.character.guid, guid))
                continue; // the client has it already (it came from another node with it)
            deliverUpdate(who, object.appearance(serverTime()));
            personalize(who, object);
        }
        foreach (player, ref seen; seesObjects)
            if (guid in seen && distanceSquared(members[player].character.position, object.position)
                > settings.visibilityDistance ^^ 2)
            {
                seen.remove(guid);
                UpdateData forget;
                forget.addOutOfRange([guid]);
                deliverUpdate(members[player], forget);
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

/// Ownership (phase 2): unowned cells do not spawn; a released region's objects go, and come back when regained.
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

/// Replication (phase 3): another node's player sees this node's objects, their changes and moves, and their going.
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
        void create(ushort peer, uint, ulong cell, ulong guid, const(ubyte)[] state) { node[peer].replicaCreated(from, cell, guid, state); }
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

/// Players on different nodes (phase 3b): each sees the other's replica, its moves, its changes and its going.
unittest
{
    import dmangos.world.replication : Replicator;
    import dmangos.world.updatefields;

    static final class Wire : Replicator
    {
        Map to;
        ushort from;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state) { to.replicaCreated(from, cell, guid, state); }
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

/// Migration (phase 4): a region's objects move to another node, and no player on any node notices.
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
        void create(ushort peer, uint, ulong cell, ulong guid, const(ubyte)[] state) { node[peer].replicaCreated(from, cell, guid, state); }
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

    // The region moves from node 1 to node 2, with the stag (now hurt) in it.
    stag.values.set!UNIT_FIELD_HEALTH(13u);
    stag.values.clearChanges();
    aOwns = false;
    Stag restored;
    const bundle = a.migrateOut((ulong) => true, 2, (MapObject o) {
        ByteWriter w;
        w.put((cast(Stag) o).values[UNIT_FIELD_HEALTH]);
        w.put((cast(Stag) o).at.x);
        return Migrant(MigrantKind.creature, 77, 0, w.data);
    });
    assert(a.isReplica(stag.guid), "node 1 keeps showing it, now as node 2's");
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

/// Migration (phase 4): a migrant that finds a fresh spawn of itself replaces it; the migrated state wins.
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


/// Players moving between nodes (phase 4b): the handover sends nothing to anyone; what follows reaches everyone.
unittest
{
    import dmangos.world.replication : Replicator;

    static final class Wire : Replicator
    {
        Map to;
        ushort from;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state) { to.replicaCreated(from, cell, guid, state); }
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

    owner.replicaCreated(1, cellKeyAt(10, 0), 0xF130_0000_0000_0099, encodePlayerState(homeWatcher.player, 0));
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

/// Speech across nodes (phase 5): a say reaches players in range on other nodes, each node delivering to its own.
unittest
{
    import dmangos.world.replication : Replicator;

    static final class Wire : Replicator
    {
        Map to;
        ushort from;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state) { to.replicaCreated(from, cell, guid, state); }
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
