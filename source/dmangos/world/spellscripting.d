/**
 * What a spell script's actions do to the units of a map, the same whichever host runs it (the caster's
 * session, or creature): a creature acted on is acted on through its own script host, by the rules its
 * own script follows; a player through the unit it is on the map.
 */
module dmangos.world.spellscripting;

import dmangos.script.api : ActionResult, CreatureHost, EntityRef;
import dmangos.world.creatureai : CombatWorld;
import dmangos.world.updatefields;

/// The creature `who` here as a script's host, acting on `world`; null if it is not here.
CreatureHost creatureHost(CombatWorld world, EntityRef who)
{
    if (world is null || !who.isCreature)
        return null;
    auto c = world.creatureAt(who.guid);
    return c is null || c.ai is null ? null : c.ai.hostIn(world);
}

/// `SMSG_PLAY_SPELL_VISUAL`: visual kit `kit` on `who`, for all who see it and a player itself.
ActionResult playVisual(CombatWorld world, EntityRef who, uint kit)
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.unit : UnitKind;

    if (world is null)
        return ActionResult.notHere;
    auto unit = world.unit(who.guid);
    if (unit.kind == UnitKind.none)
        return ActionResult.notHere;
    ByteWriter w;
    w.put(who.guid);
    w.put(kit);
    world.sendToObservers(who.guid, Opcode.SMSG_PLAY_SPELL_VISUAL, w.data);
    unit.tell(Opcode.SMSG_PLAY_SPELL_VISUAL, w.data); // a player sees its own (`SendMessageToSet`'s self)
    return ActionResult.ok;
}

/// The living creatures within `range` yards of `of` hostile to it, critters not (CMaNGOS's
/// `AnyUnfriendlyUnitInObjectRangeCheck` and `IsEnemy`), as many as `into` holds.
size_t enemiesNear(CombatWorld world, EntityRef of, float range, EntityRef[] into)
{
    import dmangos.world.relations : isEnemy;
    import dmangos.world.unit : UnitKind;

    enum uint critter = 8; // CREATURE_TYPE_CRITTER
    if (world is null)
        return 0;
    auto self = world.unit(of.guid);
    if (self.kind == UnitKind.none)
        return 0;
    const relating = self.relating;
    size_t n;
    foreach (c; world.creaturesNear(self.fighter.position, range))
    {
        if (n == into.length)
            break;
        if (c.guid == of.guid || !c.alive || c.ai is null || c.template_.creatureType == critter)
            continue;
        if (isEnemy(c.ai.relatingOf, relating, c.client))
            into[n++] = EntityRef(c.guid);
    }
    return n;
}

/// Whether a unit here is fighting (`UNIT_FLAG_IN_COMBAT`).
bool inCombat(CombatWorld world, EntityRef who)
{
    import dmangos.world.defines : UnitFlags;

    if (world is null)
        return false;
    auto v = world.unit(who.guid).fields;
    return v !is null && (v.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat) != 0;
}

/// A unit's aura of `spell` goes.
ActionResult removeAura(CombatWorld world, EntityRef who, uint spell)
{
    import dmangos.world.unit : UnitKind;

    if (world is null)
        return ActionResult.notHere;
    auto unit = world.unit(who.guid);
    if (unit.kind == UnitKind.none)
        return ActionResult.notHere;
    unit.auraRemovedBy(spell);
    return ActionResult.ok;
}

/// A unit's power of kind `power`; -1 if it has none of it (no maximum) or is not here.
int power(CombatWorld world, EntityRef who, ubyte power)
{
    if (world is null || power > 4)
        return -1;
    auto v = world.unit(who.guid).fields;
    if (v is null || v.get!UNIT_FIELD_MAXPOWER1(power) == 0)
        return -1;
    return cast(int) v.get!UNIT_FIELD_POWER1(power);
}

/// A unit's own model; 0 if it is not here.
uint nativeDisplay(CombatWorld world, EntityRef who)
{
    if (world is null)
        return 0;
    auto v = world.unit(who.guid).fields;
    return v is null ? 0 : v.get!UNIT_FIELD_NATIVEDISPLAYID;
}

/// The transform aura of `spell` on a player shows `model`: its model now, and again when a newer one goes.
ActionResult transformModel(CombatWorld world, EntityRef who, uint spell, uint model)
{
    import dmangos.world.unit : UnitKind;

    if (world is null)
        return ActionResult.notHere;
    auto unit = world.unit(who.guid);
    if (unit.kind != UnitKind.player)
        return unit.kind == UnitKind.none ? ActionResult.notHere : ActionResult.notAllowed;
    return unit.session.transformModel(spell, model) ? ActionResult.ok : ActionResult.failed;
}

/// The `SpellHost` functions every host does alike; the host has `scriptWorld()`, the map it acts on.
mixin template SpellScriptActions()
{
    import dmangos.script.api : ActionResult, EntityRef;
    static import dmangos.world.spellscripting;

    uint hostRandom(uint below)
    {
        import std.random : uniform;

        auto world = scriptWorld();
        return below == 0 || world is null ? 0 : uniform(0, below, world.random);
    }

    ActionResult hostAddThreat(EntityRef creature, EntityRef target, float amount)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), creature);
        if (h is null)
            return ActionResult.notHere;
        h.hostAddThreat(target, amount);
        return ActionResult.ok;
    }

    ActionResult hostSay(EntityRef speaker, int entry, EntityRef target)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), speaker);
        return h is null ? ActionResult.notHere : h.hostSay(entry, target);
    }

    ActionResult hostPlayVisual(EntityRef who, uint kit)
    {
        return dmangos.world.spellscripting.playVisual(scriptWorld(), who, kit);
    }

    size_t hostEnemiesNear(EntityRef of, float range, EntityRef[] into)
    {
        return dmangos.world.spellscripting.enemiesNear(scriptWorld(), of, range, into);
    }

    ActionResult hostAttack(EntityRef creature, EntityRef victim)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), creature);
        return h is null ? ActionResult.notHere : h.hostAttackBy(creature, victim);
    }

    bool hostInCombat(EntityRef who)
    {
        return dmangos.world.spellscripting.inCombat(scriptWorld(), who);
    }

    ActionResult hostUnitFlags(EntityRef creature, uint flags, bool set)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), creature);
        if (h is null)
            return ActionResult.notHere;
        h.hostUnitFlags(flags, set);
        return ActionResult.ok;
    }

    ActionResult hostRooted(EntityRef creature, bool on)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), creature);
        if (h is null)
            return ActionResult.notHere;
        h.hostRooted(on);
        return ActionResult.ok;
    }

    ActionResult hostArmed(EntityRef creature, bool armed)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), creature);
        if (h is null)
            return ActionResult.notHere;
        if (armed)
            h.hostRestoreEquipment();
        else
            h.hostEquip(0, 0, 0);
        return ActionResult.ok;
    }

    ActionResult hostRemoveAura(EntityRef who, uint spell)
    {
        return dmangos.world.spellscripting.removeAura(scriptWorld(), who, spell);
    }

    int hostPower(EntityRef who, ubyte kind)
    {
        return dmangos.world.spellscripting.power(scriptWorld(), who, kind);
    }

    uint hostNativeDisplay(EntityRef who)
    {
        return dmangos.world.spellscripting.nativeDisplay(scriptWorld(), who);
    }

    ActionResult hostSayBroadcast(EntityRef speaker, uint text, EntityRef target)
    {
        auto h = dmangos.world.spellscripting.creatureHost(scriptWorld(), speaker);
        return h is null ? ActionResult.notHere : h.hostSayBroadcast(speaker, text, target);
    }

    ActionResult hostTransformModel(EntityRef who, uint model)
    {
        return dmangos.world.spellscripting.transformModel(scriptWorld(), who, hostSpellId(), model);
    }
}
