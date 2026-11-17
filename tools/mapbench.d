// A controlled benchmark of the map alone: fixed players and objects, the same work every run
// (docs/BENCHMARKS.md, step 1 of docs/DESIGN.md). It uses the test data, so build it with -unittest
// and skip the tests when running it:
//
//   dmd -unittest -O -release -inline -Isource -of=bin/mapbench tools/mapbench.d \
//       $(find source -name '*.d' ! -name main.d)
//   bin/mapbench --DRT-testmode=run-main
import core.time : MonoTime, msecs;
import std.random : Random, uniform;
import std.stdio : writefln;
import dmangos.auth.accounts : AccountLevel;
import dmangos.world.map;
import dmangos.world.motion : MotionWorld;
import dmangos.world.movement : Position;
import dmangos.world.objects : makeGuid, HighGuid, UpdateData, UpdateValues;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : CharacterData, Player;
import dmangos.world.playercreate : CharacterBuilder, CreationSettings, KnownAbilities;
import dmangos.world.testdata;
import dmangos.world.updatefields : TypeId;

final class Viewer : Inhabitant
{
    Player player;
    size_t received;
    this(uint guid, Position position)
    {
        auto client = testClientData();
        auto world = testWorldData(client);
        CharacterData c;
        c.guid = guid; c.race = raceHuman; c.classId = classWarrior; c.level = 1; c.position = position;
        KnownAbilities abilities;
        new CharacterBuilder(world, client, CreationSettings.init, () => 1u).loadAbilities(c.race, c.classId,
            c.level, AccountLevel.player, null, null, abilities);
        player = new Player(c, abilities, world, client, testItemGuids());
    }
    @property const(Player) character() const { return player; }
    UpdateData appearanceFor(const Inhabitant, uint t) const { return player.createForOthers(t, false); }
    uint appearanceKind(const Inhabitant) const { return 0; }
    void deliver(Opcode, const(ubyte)[]) { ++received; }
}

final class Walker : Moving
{
    ulong id; Position at; float dir; bool moves;
    UpdateValues values = UpdateValues(TypeId.gameObject);
    this(ulong id, Position at, bool moves, float dir) { this.id = id; this.at = at; this.moves = moves; this.dir = dir; }
    ref UpdateValues fields() { return values; }
    @property ulong guid() const { return id; }
    @property Position position() const { return at; }
    UpdateData appearance(uint) const
    {
        import dmangos.world.objects : MovementBlock, UpdateFlags, UpdateType;
        import dmangos.world.updatefields : Visibility;
        UpdateData u; MovementBlock b; b.flags = UpdateFlags.hasPosition;
        u.addCreate(UpdateType.createObject, id, b, values, Visibility.public_);
        return u;
    }
    void tick(MotionWorld world, int diff)
    {
        import std.math : cos, sin;
        if (!moves) return;
        at.x += 0.35f * cos(dir); at.y += 0.35f * sin(dir); dir += 0.01f;
    }
    @property bool resting() const { return !moves; }
}

void main()
{
    enum float side = 3000;
    enum players = 500, objects = 30_000, ticks = 400;
    auto rng = Random(42);
    Walker[][ulong] byCell;
    Walker[] movers;
    foreach (i; 0 .. objects)
    {
        auto w = new Walker(makeGuid(HighGuid.unit, 1, i + 1), Position(uniform(0.0f, side, rng), uniform(0.0f, side, rng), 0),
            i % 3 == 0, uniform(0.0f, 6.28f, rng));
        import dmangos.world.grid : cellKeyAt;
        byCell[cellKeyAt(w.at.x, w.at.y)] ~= w;
        if (w.moves) movers ~= w;
    }
    MapObject[] spawner(uint, ulong cell) { MapObject[] r; foreach (w; byCell.get(cell, null)) r ~= w; return r; }
    auto map = new Map(0, MapSettings.init, () => 1000u, &spawner);
    Viewer[] viewers;
    foreach (i; 0 .. players)
    {
        auto v = new Viewer(i + 1, Position(uniform(0.0f, side, rng), uniform(0.0f, side, rng), 0));
        viewers ~= v;
        map.add(v);
    }
    const ubyte[8] body_ = 0;
    auto start = MonoTime.currTime;
    foreach (t; 0 .. ticks)
    {
        map.update(50.msecs);
        // A tenth of the movers start a walk this tick: a packet to their viewers.
        foreach (k; 0 .. movers.length / 10)
            map.sendToObservers(movers[(t * 97 + k * 13) % movers.length].guid, Opcode.SMSG_MONSTER_MOVE, body_);
        // A tenth of the players move two yards.
        foreach (k; 0 .. players / 10)
        {
            auto v = viewers[(t * 31 + k * 7) % players];
            v.player.movement.position.x += 2;
            map.relocated(v);
            map.sendToWatchers(v, Opcode.MSG_MOVE_HEARTBEAT, body_);
        }
    }
    const elapsed = MonoTime.currTime - start;
    size_t got; foreach (v; viewers) got += v.received;
    writefln("%s ticks, %s objects loaded, %s players: %.3f ms a tick, %s packets delivered", ticks, map.objectCount,
        players, elapsed.total!"usecs" / 1000.0 / ticks, got);
}
