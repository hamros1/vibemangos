/**
 * Landing positions for Charge and Blink (docs/SPELLS.md, step 4). Each caster applies the movement through its
 * own handlers so clients see it and the map tracks the new position.
 */
module dmangos.world.spellmoves;

import dmangos.world.map : Map;
import dmangos.world.movement : Position;
import dmangos.world.unit : UnitRef;

/**
 * Where a charge from `from` at `victim` ends: before it at its combat reach, on the ground, facing it (CMaNGOS's
 * `EffectCharge`, `MoveCharge`).
 */
Position chargeEnd(W)(W map, Position from, UnitRef victim)
{
    import std.math : atan2, sqrt;
    import dmangos.world.terrain : invalidHeight;

    const to = victim.position;
    const reach = victim.fighter.combatReach;
    const dx = from.x - to.x, dy = from.y - to.y;
    const apart = sqrt(dx * dx + dy * dy);
    Position end = to;
    if (apart > reach)
    {
        end.x = to.x + dx / apart * reach;
        end.y = to.y + dy / apart * reach;
    }
    const ground = map.groundHeight(end.x, end.y, end.z + 2, false);
    if (ground > invalidHeight)
        end.z = ground;
    end.orientation = atan2(to.y - end.y, to.x - end.x);
    return end;
}

/// The last clear point a Blink can reach along the caster's facing.
Position blinkEnd(Map map, Position from, float distance)
{
    import dmangos.world.effecthandlers : leapDestination;
    import dmangos.world.terrain : invalidHeight;

    const level = map.collision is null || !(map.groundHeight(from.x, from.y, from.z + 1, false) > invalidHeight);
    float groundAt(float x, float y, float z)
    {
        if (level) // no loaded heights at the caster
            return z - 1;
        const h = map.groundHeight(x, y, z, false);
        return h > invalidHeight && h > z - 10 ? h : float.nan;
    }

    bool clear(Position a, Position b)
    {
        return map.inLineOfSight(a, b);
    }

    return leapDestination(from, distance, &groundAt, &clear);
}
