/// Associates the database's event spawns with their ground camp or hovering necropolis.
module dmangos.world.scourgelayout;

import dmangos.world.scourge : CampDefeated, InvasionState, invasionZones;
import dmangos.world.movement : Position;
import dmangos.world.worlddata : WorldData;

struct InvasionSite
{
    uint map, spawn;
    Position position;
    ubyte zone, ship, camp;
    bool wholeShip;

    CampDefeated stamp(const ref InvasionState state) const
    {
        return CampDefeated(state.zones[zone].generation, zone, ship, camp, state.campaign);
    }
    bool present(const ref InvasionState state) const
    {
        if (!wholeShip) return !state.cleared(stamp(state));
        foreach (ubyte i; 0 .. 3)
        {
            auto c = stamp(state);
            c.camp = i;
            if (!state.cleared(c)) return true;
        }
        return false;
    }
}

final class InvasionLayout
{
    InvasionSite[] ships, camps;
    InvasionSite[uint] objects, creatures;

    private static float distance(Position a, Position b)
    {
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
    }

    static const(InvasionSite)* nearest(const(InvasionSite)[] sites, uint map, Position at, int zone = -1)
    {
        const(InvasionSite)* best;
        float closest = float.max;
        foreach (ref s; sites)
        {
            if (s.map != map || (zone >= 0 && s.zone != zone)) continue;
            const d = distance(s.position, at);
            if (d < closest) { best = &s; closest = d; }
        }
        return best;
    }

    /// The summon retains its point of origin even if a player draws it away from its camp.
    bool actorPresent(Spawn)(uint entry, const ref Spawn spawn, const ref InvasionState state) const
    {
        switch (entry)
        {
        case 16136,16172,16230,16143,16306,16336,16338,16298,16141,16299,14697,16379,16380:
            const p = Position(spawn.x, spawn.y, spawn.z);
            const site = nearest(camps, spawn.map, p);
            return site is null || distance(p, site.position) > 125 * 125 || site.present(state);
        default:
            return true;
        }
    }

    this(WorldData data)
    {
        import std.algorithm.sorting : sort;
        foreach (ref row; data.creatureSpawns)
        {
            const event = data.creatureGameEvents.get(row.guid, 0);
            if (row.entry == 16421 && event >= 90 && event <= 95)
                ships ~= InvasionSite(row.map, row.guid, Position(row.x,row.y,row.z), cast(ubyte)(event - 90), 0, 0, true);
        }
        if (!ships.length) return;
        ships.sort!((a,b) => a.spawn < b.spawn);
        ubyte[6] shipCount;
        foreach (ref ship; ships) ship.ship = shipCount[ship.zone]++;
        foreach (ref row; data.gameObjectSpawns)
        {
            const event = data.gameObjectGameEvents.get(row.guid, 0);
            if (row.entry != 181136 || event < 90 || event > 95) continue;
            const pos = Position(row.x,row.y,row.z);
            if (const ship = nearest(ships, row.map, pos, event - 90))
                camps ~= InvasionSite(row.map, row.guid, pos, ship.zone, ship.ship);
        }
        camps.sort!((a,b) => a.spawn < b.spawn);
        ubyte[3][6] campCount;
        foreach (ref camp; camps)
            if (camp.ship < 3)
                camp.camp = campCount[camp.zone][camp.ship]++;
        foreach (ref row; data.gameObjectSpawns)
        {
            const event = data.gameObjectGameEvents.get(row.guid, 0);
            if (event < 90 || event > 95) continue;
            const airborne = row.entry == 181154 || row.entry == 181215 || row.entry == 181223
                || row.entry == 181373 || row.entry == 181374 || row.entry == 181214;
            if (const site = nearest(airborne ? ships : camps, row.map, Position(row.x,row.y,row.z), event - 90))
                objects[row.guid] = *site;
        }
        foreach (ref row; data.creatureSpawns)
        {
            const event = data.creatureGameEvents.get(row.guid, 0);
            if (event < 90 || event > 95) continue;
            const airborne = row.entry == 16401 || row.entry == 16421;
            if (const site = nearest(airborne ? ships : camps, row.map, Position(row.x,row.y,row.z), event - 90))
                creatures[row.guid] = *site;
        }
    }
}
