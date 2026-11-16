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
 */
module dmangos.world.map;

import std.math : floor;

import dmangos.serialization : serialize;
import dmangos.bytes : ByteWriter;
import dmangos.world.movement : Position;
import dmangos.world.objects : UpdateData;
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

/// Side of a grid cell, in yards (`SIZE_OF_GRID_CELL`: 533.33 / 8).
enum float cellSize = 533.3333f / 8;

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
    }

    invariant (members.length == cellOf.length && members.length == sees.length);

    ///
    this(uint id, MapSettings settings, uint delegate() serverTime)
    in (serverTime !is null)
    {
        this.id = id;
        this.settings = settings;
        this.serverTime = serverTime;
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
        const reach = cast(int)(range / cellSize) + 1;
        const cx = cellCoordinate(center.x), cy = cellCoordinate(center.y);
        foreach (x; cx - reach .. cx + reach + 1)
            foreach (y; cy - reach .. cy + reach + 1)
                if (const cell = cellKey(x, y) in cells)
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
        const key = cellKey(cellCoordinate(position.x), cellCoordinate(position.y));
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
        if (gone.length == 0)
            return;
        foreach (other; gone)
        {
            sees[guid].remove(other);
            sees[other].remove(guid);
            UpdateData forget;
            forget.addOutOfRange([guid]);
            deliverUpdate(members[other], forget);
        }
        UpdateData forgetAll;
        forgetAll.addOutOfRange(gone);
        deliverUpdate(who, forgetAll);
    }

    static int cellCoordinate(float coordinate) pure nothrow @nogc @safe
    {
        return cast(int) floor(coordinate / cellSize);
    }

    static ulong cellKey(int x, int y) pure nothrow @nogc @safe
    {
        return ulong(cast(uint) x) << 32 | cast(uint) y;
    }

    static float distanceSquared(Position a, Position b) pure nothrow @nogc @safe
    {
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
    }
}

version (unittest)
{
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
    assert(alice.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT] && bob.take() == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]);
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
