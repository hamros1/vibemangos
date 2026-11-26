/**
 * What a spell puts into the world, whoever casts it (docs/SPELLS.md, step 4): game objects standing by the caster.
 * A player's pets, guardians, companions and totems keep their owner's bookkeeping in `pethandlers.d` and
 * `guardians.d`; what needs no more than a caster is here.
 */
module dmangos.world.spellsummons;

import dmangos.world.caster : Caster;
import dmangos.world.movement : Position;
import dmangos.world.spellcast : SpellTargets;
import dmangos.world.spells : SpellInfo;

/**
 * `SPELL_EFFECT_SUMMON_OBJECT_WILD` (and a creature's `TRANS_DOOR`): game object `spell.miscValue[i]` at the
 * destination or a yard before the caster on the ground, for the spell's duration (its object without an owner:
 * CMaNGOS's `EffectSummonObjectWild`, `EffectTransmitted`).
 */
void summonWildObject(ref Caster caster, const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
{
    auto context = caster.context;
    const entry = cast(uint) spell.miscValue[i];
    if (entry !in context.data.gameObjectTemplates)
        return;
    context.placeWildGameObject(caster.map, entry, wildObjectDestination(caster, targets), wildObjectDuration(caster, spell));
}

/// A creature's `SPELL_EFFECT_SUMMON_OBJECT_SLOT1` .. 4: its trap ahead of it, or at the cast's destination.
void summonCreatureTrap(ref Caster caster, const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
{
    auto creature = caster.creature;
    if (creature is null)
        return;
    caster.context.summonCreatureTrap(caster.map, creature, cast(uint) spell.miscValue[i],
        wildObjectDestination(caster, targets), wildObjectDuration(caster, spell));
}

package enum OutdoorObjectCast { ordinary, committed, failed }

/// Saves an immediate object-only spell's placement before its cast success goes to the client.
package OutdoorObjectCast commitWildObjectCast(ref Caster caster, const(SpellInfo)* spell, const ref SpellTargets targets)
{
    const entry = cast(uint) spell.miscValue[0];
    const seconds = wildObjectDuration(caster, spell);
    if (!caster.context.usesOutdoorObjectQueue(caster.map, entry, seconds))
        return OutdoorObjectCast.ordinary;
    return caster.context.queueOutdoorObject(caster.map, entry, wildObjectDestination(caster, targets), seconds)
        ? OutdoorObjectCast.committed : OutdoorObjectCast.failed;
}

private Position wildObjectDestination(ref Caster caster, const ref SpellTargets targets)
{
    import std.math : cos, sin;
    import dmangos.world.spellcast : TargetFlags;

    const me = caster.position;
    auto at = Position(me.x + cos(me.orientation), me.y + sin(me.orientation), me.z, me.orientation);
    if (targets.mask & TargetFlags.destLocation)
        at = Position(targets.dest[0], targets.dest[1], targets.dest[2], me.orientation);
    else
    {
        const ground = caster.map.groundHeight(at.x, at.y, me.z + 2, false);
        if (ground > -100_000 && (ground - at.z) ^^ 2 < 25)
            at.z = ground;
    }
    return at;
}

private uint wildObjectDuration(ref Caster caster, const(SpellInfo)* spell)
{
    import dmangos.world.spellcast : duration;

    const ms = caster.modDuration(spell, duration(*spell, caster.context.client, caster.level));
    return ms > 0 ? cast(uint)(ms / 1000) : 0;
}

/**
 * `SPELL_EFFECT_SUMMON_TOTEM` (and its four slots, `slot` 0 to 3; `uint.max`: none): the effect's creature two yards
 * from the caster (its slot's side), of its faction and level, its health the effect's value, for the spell's
 * duration, standing and casting (CMaNGOS's `EffectSummonTotem`). One whose spell takes no time to cast holds that
 * spell's aura on itself, whence it reaches its owner's party (`dmangos.world.aurahandlers`); one whose spell takes
 * time casts it at its owner's enemies (`totemsAct`). Returns it; null if it could not be made.
 */
imported!"dmangos.world.creature".Creature summonTotem(ref Caster caster, const(SpellInfo)* spell, size_t i,
    int value, uint slot)
{
    import std.algorithm.comparison : max;
    import std.math : cos, PI, sin;
    import dmangos.world.auras : makeAura;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.creatureai : ReactState;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.spellcast : castTime, duration, effectValue;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.updatefields;

    auto context = caster.context;
    auto map = caster.map;
    const entry = cast(uint) spell.miscValue[i];
    if (entry !in context.data.creatureTemplates)
        return null;
    const me = caster.position;
    const angle = slot != uint.max ? PI / 4 - slot * PI / 2 : 0;
    const o = me.orientation + angle;
    auto at = Position(me.x + 2 * cos(o), me.y + 2 * sin(o), me.z, me.orientation);
    const ground = map.groundHeight(at.x, at.y, at.z + 2, false);
    if (ground > -100_000 && (ground - at.z) ^^ 2 < 25)
        at.z = ground;
    const level = caster.level;
    const ms = caster.modDuration(spell, duration(*spell, context.client, level)); // (Improved Fire Totems)
    auto totem = context.summonCreature(map, entry, at, ms > 0 ? TempSpawnType.timedOrDead : TempSpawnType.dead,
        ms > 0 ? ms : 0, caster.guid);
    if (totem is null)
        return null;
    auto v = &totem.values;
    const faction = caster.fields.get!UNIT_FIELD_FACTIONTEMPLATE;
    v.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
    totem.factionTemplate = context.client.factionTemplates.lookup(faction);
    v.set!UNIT_FIELD_LEVEL(level);
    if (value > 0)
    {
        v.set!UNIT_FIELD_MAXHEALTH(cast(uint) value);
        v.set!UNIT_FIELD_HEALTH(cast(uint) value);
    }
    v.set!UNIT_CREATED_BY_SPELL(spell.id);
    v.set!UNIT_FIELD_SUMMONEDBY(caster.guid);
    v.set!UNIT_FIELD_CREATEDBY(caster.guid);
    if (caster.kind == imported!"dmangos.world.unit".UnitKind.player) // a player's is player-controlled (PvP)
        v.set!UNIT_FIELD_FLAGS(v.get!UNIT_FIELD_FLAGS | UnitFlags.playerControlled);
    totem.totemOwner = caster.guid;
    totem.ai.react = ReactState.passive; // it stands and casts; it does not fight
    totem.ai.scriptMelee(false);
    totem.ai.scriptCombatMovement(false);
    if (const s = entry in context.data.creatureControlSpells)
        if (const info = context.data.spells.spell((*s)[0]))
        {
            totem.totemSpell = (*s)[0];
            totem.totemActive = castTime(*info, context.client, level) > 0;
            if (!totem.totemActive)
            {
                // Its aura on itself, whence it reaches the party.
                int[3] amounts;
                foreach (j; 0 .. 3)
                    amounts[j] = caster.character !is null // (Enhancing Totems)
                        ? caster.character.effectMod(info, j, effectValue(*info, j, level, 0))
                        : effectValue(*info, j, level, 0);
                auto aura = makeAura(info, totem.guid, level, -1, true, amounts);
                // Its first tick: sooner by the owner's talents (Improved Fire Totems: Fire Nova Totem's nova).
                foreach (j; 0 .. 3)
                    if (aura.period[j] > 0)
                        aura.period[j] = aura.periodTimer[j] = max(1, caster.spellMod(SpellModOp.activationTime, info,
                            aura.period[j]));
                bool isNew;
                totem.auras.apply(aura, totem.values, isNew);
            }
        }
    map.flushObjectChanges(totem);
    return totem;
}

/**
 * Each tick: each active totem of `owner`'s (one whose spell takes time to cast: Searing Totem) casts its spell at
 * the nearest enemy within range. A player's totem only helps fights its owner or group has already joined.
 */
void totemsAct(ref Caster owner, imported!"dmangos.world.creature".Creature[] totems)
{
    import std.algorithm.searching : any;
    import dmangos.world.spellcast : range;
    import dmangos.world.unit : UnitKind, UnitRef;

    auto map = owner.map;
    auto context = owner.context;
    const ownerGuid = owner.guid;
    auto group = owner.kind == UnitKind.player ? context.groups.of(ownerGuid) : null;
    bool fightingOwnerOrGroup(ulong guid)
    {
        if (guid == ownerGuid)
            return true;
        if (auto helper = map.creatureAt(guid))
        {
            guid = helper.petOwner ? helper.petOwner : helper.guardianOwner;
            if (guid == ownerGuid)
                return true;
        }
        return group !is null && group.isMember(guid);
    }
    foreach (totem; totems)
    {
        if (!totem.alive || !totem.totemActive || totem.ai is null || totem.ai.castingNow)
            continue;
        const info = context.data.spells.spell(totem.totemSpell);
        if (info is null)
            continue;
        const reach = range(*info, context.client)[1];
        ulong nearest;
        float best = reach * reach;
        void consider(UnitRef u)
        {
            const p = u.position;
            const d = (p.x - totem.position.x) ^^ 2 + (p.y - totem.position.y) ^^ 2;
            if (d <= best && u.alive && owner.hostileTo(u))
            {
                best = d;
                nearest = u.combatGuid;
            }
        }
        foreach (c; map.creaturesNear(totem.position, reach))
            if (c.alive && c !is totem && !c.totemOwner && c.petOwner != ownerGuid && c.ai !is null)
            {
                const threat = c.ai.threatList;
                if (owner.kind == UnitKind.player && !any!fightingOwnerOrGroup(threat.byKey))
                    continue;
                consider(map.unitOf(c));
            }
        if (owner.kind == UnitKind.creature) // a creature's at the players it fights too
            foreach (u; map.playersNear(totem.position, reach))
                consider(u);
        if (nearest)
            totem.ai.castSpell(info, nearest, 0);
    }
}
