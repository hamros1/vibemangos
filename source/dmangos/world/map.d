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
 */
module dmangos.world.map;

import core.time : Duration;

import dmangos.serialization : serialize;
import dmangos.bytes : ByteWriter;
public import dmangos.world.grid : cellSize;
import dmangos.world.grid : cellCoordinate, cellKey, cellKeyAt;
import dmangos.world.movement : Position;
import dmangos.world.objects : seenByEveryone, UpdateData, UpdateValues;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ServerDestroyObject;
import dmangos.world.player : Player;

/// What the map needs from a player in it.
interface Inhabitant
{
    /// The character being played.
    @property const(Player) character() const;

    /// Frames and queues a packet for this player's client.
    void deliver(Opcode opcode, const(ubyte)[] body_);

    /// The create block `viewer` gets when this player comes into its sight.
    UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const;
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
    const packet = update.build();
    to.deliver(packet.compressed ? Opcode.SMSG_COMPRESSED_UPDATE_OBJECT : Opcode.SMSG_UPDATE_OBJECT, packet.body_);
}

/// See the module documentation.
final class Map
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
    }

    invariant (members.length == cellOf.length && members.length == sees.length
        && members.length == seesObjects.length);

    ///
    this(uint id, MapSettings settings, uint delegate() serverTime, Spawner spawner = null)
    in (serverTime !is null)
    {
        this.id = id;
        this.settings = settings;
        this.serverTime = serverTime;
        this.spawner = spawner;
    }

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
        if (object.fields.hasChangesFor(seenByEveryone))
        {
            UpdateData update;
            update.addValues(object.guid, object.fields, seenByEveryone);
            foreach (guid, seen; seesObjects)
                if (object.guid in seen)
                    deliverUpdate(members[guid], update);
        }
        object.fields.clearChanges();
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
        if (spawner is null || key in loadedCells)
            return;
        loadedCells[key] = true;
        foreach (object; spawner(id, key))
        {
            objects[object.guid] = object;
            objectCells[key][object.guid] = true;
        }
    }

    /// One tick of the world update (`Map::Update`): creatures and game objects come with their update.
    void update(Duration elapsed)
    {
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
    }

    /// `Map::Remove`: takes a player off the map; those who saw it are told to destroy it.
    void remove(Inhabitant who)
    in (who.character.guid in members, "only a player on the map can leave it")
    {
        const guid = who.character.guid;
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
        place(guid, position);
        if (distanceSquared(visibilityAt[guid], position) >= settings.relocationLimit ^^ 2)
            updateVisibility(who);
    }

    /// Delivers a packet to every player that sees `from`, and to `from` itself if `includeSelf`.
    void sendToWatchers(Inhabitant from, Opcode opcode, const(ubyte)[] body_, bool includeSelf = false)
    {
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

    /// Delivers a packet to every player within `range` yards of `center`, whether they see each other or not.
    void sendInRange(Position center, float range, Opcode opcode, const(ubyte)[] body_)
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
    void place(ulong guid, Position position)
    {
        const key = cellKeyAt(position.x, position.y);
        if (const old = guid in cellOf)
        {
            if (*old == key)
                return;
            cells[*old].remove(guid);
        }
        cells[key][guid] = true;
        cellOf[guid] = key;
    }

    /// `Player::UpdateVisibilityOf` for every player near `who`, both ways.
    void updateVisibility(Inhabitant who)
    {
        const guid = who.character.guid;
        visibilityAt[guid] = who.character.position;

        bool[ulong] inSight;
        foreach (other; near(who.character.position, settings.visibilityDistance))
            if (other.character.guid != guid)
                inSight[other.character.guid] = true;

        // Newly in sight: each gets the other's create block.
        foreach (other, _; inSight)
            if (other !in sees[guid])
            {
                sees[guid][other] = true;
                sees[other][guid] = true;
                deliverUpdate(who, members[other].appearanceFor(who, serverTime()));
                deliverUpdate(members[other], who.appearanceFor(members[other], serverTime()));
            }

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
        foreach (object; objectsNear(who.character.position, settings.visibilityDistance))
        {
            objectsInSight[object.guid] = true;
            if (object.guid in seesObjects[guid])
                continue;
            seesObjects[guid][object.guid] = true;
            created.append(object.appearance(serverTime()));
            if (created.blockCount >= maxBlocksPerPacket)
            {
                deliverUpdate(who, created);
                created = UpdateData.init;
            }
        }
        if (!created.empty)
            deliverUpdate(who, created);
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
            player = new Player(c, abilities, world, client);
        }

        @property const(Player) character() const
        {
            return player;
        }

        UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const
        {
            return player.createForOthers(serverTime, false);
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
