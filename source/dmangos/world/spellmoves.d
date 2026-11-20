/**
 * Where a spell moves its caster, whoever it is (docs/SPELLS.md, step 4): a charge's end. How the caster gets there
 * is its kind's: a player's client is shown the run and the player is put there (`effecthandlers.d`), a creature
 * runs it as a spline (`creaturecasting.d`).
 */
module dmangos.world.spellmoves;

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
