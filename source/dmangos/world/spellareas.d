/**
 * Persistent area auras (`SPELL_EFFECT_PERSISTENT_AREA_AURA`: Blizzard, Rain of Fire, Flamestrike's burning ground,
 * a boss's poison cloud), whoever casts them (docs/SPELLS.md, step 4).
 *
 * The spot is a `DynamicObject` the clients see; its caster keeps the list of its spots (a player's
 * `SpellHandlers`, a creature's `CreatureCasting`) and ticks them through `updatePersistentAreas`: each period the
 * enemies of the caster inside take the tick's damage, or (another aura: Flare's, a slow) have its aura for as long
 * as they stay (CMaNGOS's `PersistentAreaAura`).
 */
module dmangos.world.spellareas;

import dmangos.world.caster : Caster;
import dmangos.world.dynobject : DynamicObject;
import dmangos.world.spellcast : SpellTargets;
import dmangos.world.spells : SpellInfo;

/// A persistent area aura's spot under way.
struct PersistentArea
{
    DynamicObject spot;
    const(SpellInfo)* spell;
    size_t effect;
    int value;      /// each tick's damage
    int amplitude;  /// ms between ticks
    int timer;      /// ms to the next tick
    int left;       /// ms it lasts yet
    bool[ulong] holding; /// those its aura is on: till they leave it, or it ends
}

/**
 * The spot of effect `i` of `spell` (its radius and duration by the caster's modifiers) at the cast's destination,
 * or where the caster stands; added to `areas`.
 */
void makePersistentArea(ref Caster caster, ref PersistentArea[] areas, const(SpellInfo)* spell, size_t i,
    const ref SpellTargets targets, int value)
{
    import dmangos.world.movement : Position;
    import dmangos.world.spellcast : duration, radius, TargetFlags;
    import dmangos.world.spellmods : SpellModOp;

    auto context = caster.context;
    const r = caster.spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client)),
        ms = caster.modDuration(spell, duration(*spell, context.client, caster.level));
    if (r <= 0 || ms <= 0)
        return;
    Position at = caster.position;
    if (targets.mask & TargetFlags.destLocation)
        at = Position(targets.dest[0], targets.dest[1], targets.dest[2], at.orientation);
    auto spot = new DynamicObject(context.nextTemporaryCounter(), caster.guid, spell.id, i, r, at);
    caster.map.addObject(spot);
    const amplitude = spell.casting.amplitude[i] > 0 ? spell.casting.amplitude[i] : 1000;
    areas ~= PersistentArea(spot, spell, i, value > 0 ? value : 0, amplitude, amplitude, ms);
}

/// A persistent area's aura amounts: its own effect's (the spot's value), the others' as cast.
private int[3] areaAuraValues(ref Caster caster, const ref PersistentArea area)
{
    import std.random : uniform01;
    import dmangos.world.spellcast : effectValue;

    int[3] values;
    foreach (j; 0 .. 3)
        values[j] = j == area.effect ? area.value
            : effectValue(*area.spell, j, caster.level, uniform01(caster.map.random));
    return values;
}

/**
 * A persistent area's tick of damage (Blizzard's, Rain of Fire's): its value, the caster's spell power by the
 * tick's coefficient (`bonusCoefficient`), the damage over time modifiers on both (`SPELLMOD_DOT`: Piercing Ice).
 */
private uint areaTick(ref Caster caster, const ref PersistentArea area)
{
    import dmangos.world.spellcast : bonusCoefficient;
    import dmangos.world.spellmods : SpellModOp;

    int tick = area.value;
    const school = area.spell.casting.school;
    if (school != 0)
        if (const done = caster.spellPower(1 << school))
            if (done > 0)
                tick += cast(int)(done * bonusCoefficient(*area.spell, area.effect, caster.context.client, caster.level));
    tick = caster.spellMod(SpellModOp.dot, area.spell, tick);
    return tick > 0 ? tick : 0;
}

/// The spots' ticks and ends.
void updatePersistentAreas(ref Caster caster, ref PersistentArea[] areas, int diff)
{
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.spelldamage : spellDamage, SpellDamage;
    import dmangos.world.spellcast : radius;
    import dmangos.world.unit : Blow, dealDamage, UnitKind, UnitRef;

    auto map = caster.map;
    foreach_reverse (k, ref area; areas)
    {
        area.left -= diff;
        area.timer -= diff;
        while (area.timer <= 0 && area.left > -area.amplitude)
        {
            area.timer += area.amplitude;
            const r = radius(*area.spell, area.effect, caster.context.client);
            const at = area.spot.position;
            bool inside(Position p)
            {
                return (p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2 <= r * r;
            }
            // Damage over time hurts; another aura (Flare's, a slow) is on those inside for what the area has
            // left, until they leave it.
            const auraType = area.spell.casting.applyAuraName[area.effect];
            const hurts = auraType == 0 || auraType == AuraType.periodicDamage;
            const holdMs = area.left > area.amplitude ? area.left : area.amplitude;
            bool[ulong] inArea;
            void reach(UnitRef unit)
            {
                if (!unit.alive || !inside(unit.position) || !caster.hostileTo(unit))
                    return;
                if (hurts)
                {
                    spellDamage(caster, area.spell, unit, areaTick(caster, area), area.spell.casting.school,
                        SpellDamage(false, -1, true));
                    if (auto p = caster.character)
                        p.classAreaTick(area.spell, unit); // Improved Blizzard's chill
                    return;
                }
                const guid = unit.combatGuid;
                inArea[guid] = true;
                if (guid in area.holding)
                    return;
                area.holding[guid] = true;
                auto aura = makeAura(area.spell, caster.guid, caster.level, holdMs, false, areaAuraValues(caster, area));
                final switch (unit.kind)
                {
                case UnitKind.none:
                    break;
                case UnitKind.creature:
                    bool isNew;
                    unit.creature.receiveAura(aura, map, isNew);
                    map.flushObjectChanges(unit.creature);
                    if (isNew) // an attack: it fights back
                    {
                        caster.enteredCombat(0);
                        dealDamage(caster.unit, unit, 0, Blow.spell());
                    }
                    break;
                case UnitKind.player:
                    unit.session.addAura(aura);
                    break;
                }
            }
            foreach (creature; map.creaturesNear(at, r))
                if (creature.guid != caster.guid && creature.ai !is null)
                    reach(map.unitOf(creature));
            foreach (u; map.playersNear(at, r)) // players it may fight (a duel's opponent, world PvP, a creature's foes)
                reach(u);
            foreach (guid; area.holding.keys) // those who left it lose it
                if (guid !in inArea)
                {
                    loseAreaAura(caster, guid, area.spell);
                    area.holding.remove(guid);
                }
        }
        if (area.left <= 0)
        {
            foreach (guid; area.holding.keys)
                loseAreaAura(caster, guid, area.spell);
            map.removeObject(area.spot.guid);
            areas = areas[0 .. k] ~ areas[k + 1 .. $];
        }
    }
}

/// `guid` loses `caster`'s aura of the persistent area of `spell`.
private void loseAreaAura(ref Caster caster, ulong guid, const(SpellInfo)* spell)
{
    import dmangos.world.unit : UnitKind;

    auto unit = caster.map.unit(guid);
    final switch (unit.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.creature:
        if (auto aura = unit.creature.auras.find(spell.id))
            if (aura.caster == caster.guid)
            {
                unit.creature.loseAura(aura, caster.map);
                caster.map.flushCreature(unit.creature);
            }
        return;
    case UnitKind.player:
        if (auto aura = unit.session.player.auras.find(spell.id))
            if (aura.caster == caster.guid)
                unit.session.removeAura(aura);
        return;
    }
}

/// Every spot of `areas` goes (its caster left, died, or stopped channelling them: `spell`, if not null).
void endPersistentAreas(ref Caster caster, ref PersistentArea[] areas, const(SpellInfo)* spell = null)
{
    foreach_reverse (k, ref area; areas)
        if (spell is null || area.spell is spell)
        {
            caster.map.removeObject(area.spot.guid);
            areas = areas[0 .. k] ~ areas[k + 1 .. $];
        }
}
