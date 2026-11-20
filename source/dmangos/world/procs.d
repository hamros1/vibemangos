/**
 * Procs: an aura that does something when something happens to its bearer (CMaNGOS's `Unit::ProcDamageAndSpell`
 * and `UnitAuraProcHandler.cpp`). What happened is a set of `ProcFlag`s (a swing dealt, a spell taken, a tick...)
 * and a `ProcHit`: the spell (none for a swing), how it landed (`ProcEx`: a hit, a crit, a dodge, a block) and
 * its damage. An aura procs on it when its flags (its `spell_proc_event` row's, else its spell's) share one,
 * when the row's school, family and hit kinds allow it, when the spell that hit is one of those its effect
 * affects (the row's family mask, else `spell_affect`'s or `EffectItemType`'s), when its weapon is in hand, when it
 * is off cooldown, and when its chance (the row's, its spell's, or a rate a minute at the weapon's speed) rolls.
 *
 * What a proc does is its effect's: a Proc Trigger Spell casts its spell at the other unit (its own targets decide
 * where it lands), a dummy or an override class script does its class's thing (`dmangos.world.classspells`); a
 * proc uses a charge, and an aura out of charges goes. Spells cast by procs set off no procs themselves.
 */
module dmangos.world.procs;

import dmangos.world.aurahandlers : ProcFlag;
import dmangos.world.spells : SpellInfo, SpellProcEvent;

/// How a hit that may set off procs landed (`ProcFlagsEx`).
enum ProcEx : uint
{
    none = 0,
    normalHit = 0x1,
    criticalHit = 0x2,
    miss = 0x4,
    resist = 0x8,
    dodge = 0x10,
    parry = 0x20,
    block = 0x40,
    evade = 0x80,
    immune = 0x100,
    deflect = 0x200,
    absorb = 0x400,
    reflect = 0x800,
    triggerOnNoDamage = 0x10000, /// `PROC_EX_EX_TRIGGER_ON_NO_DAMAGE`: a hit procs it even without damage
    periodicPositive = 0x40000,
    castEnd = 0x80000,
}

/// What set procs off: the spell (null: a swing or an auto shot), how it landed, its damage (or healing).
struct ProcHit
{
    const(SpellInfo)* spell;
    uint procEx = ProcEx.normalHit;
    uint damage;
    ubyte hand;            /// the `AttackType` of a swing or weapon ability (a rate a minute is at its speed)
    bool damaging = true;  /// it dealt damage or healing (a debuff that lands deals none)
}

/// The proc flags a spell's hit is (CMaNGOS's `Spell::PrepareMasksForProcSystem`): for its caster, and with
/// `victim` for its target. A melee or ranged ability is one, a spell is helpful or harmful.
uint spellProcFlags(const ref SpellInfo spell, bool positive, bool victim) pure nothrow @nogc @safe
{
    import dmangos.world.spellids : DamageClass;

    enum uint isAbility = 0x10, autoRepeat = 0x20; // SPELL_ATTR_IS_ABILITY; SPELL_ATTR_EX2_AUTO_REPEAT
    uint flag;
    if (spell.casting.dmgClass == DamageClass.melee)
        flag = ProcFlag.dealMeleeAbility;
    else if (spell.casting.dmgClass == DamageClass.ranged)
        flag = spell.attributesEx2 & autoRepeat ? ProcFlag.dealRangedAttack : ProcFlag.dealRangedAbility;
    else if (positive)
        flag = spell.attributes & isAbility ? ProcFlag.dealHelpfulAbility : ProcFlag.dealHelpfulSpell;
    else if (spell.attributesEx2 & autoRepeat)
        flag = ProcFlag.dealRangedAttack; // a wand
    else
        flag = spell.attributes & isAbility ? ProcFlag.dealHarmfulAbility : ProcFlag.dealHarmfulSpell;
    return victim ? flag << 1 : flag; // each taken flag is the dealt one's next bit
}

/// `ProcEx` of a swing's outcome (`dmangos.world.combat.MeleeHitOutcome`).
uint procExOfSwing(uint outcome) pure nothrow @nogc @safe
{
    import dmangos.world.combat : MeleeHitOutcome;

    switch (outcome)
    {
    case MeleeHitOutcome.miss:
        return ProcEx.miss;
    case MeleeHitOutcome.dodge:
        return ProcEx.dodge;
    case MeleeHitOutcome.parry:
        return ProcEx.parry;
    case MeleeHitOutcome.block:
        return ProcEx.block | ProcEx.normalHit;
    case MeleeHitOutcome.evade:
        return ProcEx.evade;
    case MeleeHitOutcome.crit:
        return ProcEx.criticalHit;
    default:
        return ProcEx.normalHit;
    }
}

/**
 * Whether an aura whose proc flags are `auraFlags` (and its `spell_proc_event` row `event`, or null) procs at all
 * on `flags` happening with `hit` (`SpellMgr::IsSpellProcEventCanTriggeredBy`): a kill always; a tick only for an
 * aura of ticks or of harmful spells; the row's school and family; then its hit kinds (none listed: a hit or a crit).
 */
bool procEventMatches(uint auraFlags, const(SpellProcEvent)* event, uint flags, const ref ProcHit hit)
    pure nothrow @nogc @safe
{
    if (!(auraFlags & flags))
        return false;
    if (auraFlags & flags & ProcFlag.kill)
        return true;
    if ((flags & auraFlags & ProcFlag.dealHarmfulPeriodic) && auraFlags != ProcFlag.dealHarmfulPeriodic
            && !(auraFlags & (ProcFlag.dealHarmfulSpell | ProcFlag.dealHarmfulAbility)))
        return false;
    if ((flags & auraFlags & ProcFlag.takeHarmfulPeriodic) && auraFlags != ProcFlag.takeHarmfulPeriodic
            && !(auraFlags & (ProcFlag.takeHarmfulSpell | ProcFlag.takeHarmfulAbility)))
        return false;
    uint required;
    if (event !is null)
    {
        required = event.procEx;
        if (hit.spell is null)
        {
            if (event.schoolMask && !(event.schoolMask & 1)) // a swing is physical
                return false;
        }
        else
        {
            if (event.schoolMask && !(event.schoolMask & (1u << hit.spell.casting.school)))
                return false;
            if (event.family && event.family != hit.spell.casting.spellFamilyName)
                return false;
        }
    }
    if (required == ProcEx.none)
        return (hit.procEx & (ProcEx.castEnd | ProcEx.normalHit | ProcEx.criticalHit)) != 0;
    if (required & ProcEx.triggerOnNoDamage)
        return true;
    return (required & hit.procEx) != 0;
}

/// The spell family mask effect `i` of `spell` affects: `spell_affect`'s, else `EffectItemType`.
ulong affectMaskOf(const(SpellInfo)* spell, size_t i) pure nothrow @nogc @safe
{
    return spell.casting.affectMask[i] ? spell.casting.affectMask[i] : spell.itemType[i];
}

/**
 * Whether effect `i` of the aura of `auraSpell` procs on `hit`'s spell (`Unit::IsTriggeredAtSpellProcEvent`'s
 * per-effect checks and `Aura::CanProcFrom`): the row's family mask for the effect, else the effect's own affect mask
 * (none: any spell that dealt damage or healing, or any at all if the row asks for no damage). A swing passes.
 */
bool effectProcsOn(const(SpellInfo)* auraSpell, size_t i, const(SpellProcEvent)* event, const ref ProcHit hit)
    pure nothrow @nogc @safe
{
    if (hit.spell is null)
        return true;
    if (event !is null && event.familyMask[i])
        return (hit.spell.casting.spellFamilyFlags & event.familyMask[i]) != 0;
    const required = event is null ? ProcEx.none : event.procEx;
    const mask = event !is null && event.schoolMask ? 0 : affectMaskOf(auraSpell, i);
    if (mask)
        return (hit.spell.casting.spellFamilyFlags & mask) != 0;
    if (required & ProcEx.triggerOnNoDamage)
        return true;
    if (required == ProcEx.none)
        return (hit.procEx & ProcEx.castEnd) || ((hit.procEx & (ProcEx.normalHit | ProcEx.criticalHit)) && hit.damaging);
    return !((required & (ProcEx.normalHit | ProcEx.criticalHit) & hit.procEx) && !hit.damaging);
}

/// `Unit::GetPPMProcChance`: the chance in percent of a proc `ppm` times a minute at `attackTime` ms a swing.
float ppmChance(uint attackTime, float ppm) pure nothrow @nogc @safe
{
    return attackTime * ppm / 600.0f;
}

/// The flags of what happened to the unit itself (a swing, a spell, a tick taken), as opposed to what it did.
enum uint takenProcFlags = ProcFlag.takeMeleeSwing | ProcFlag.takeMeleeAbility | ProcFlag.takeRangedAttack
    | ProcFlag.takeRangedAbility | ProcFlag.takeHelpfulAbility | ProcFlag.takeHarmfulAbility | ProcFlag.takeHelpfulSpell
    | ProcFlag.takeHarmfulSpell | ProcFlag.takeHarmfulPeriodic;

/// The proc engine of a player (mixed into `dmangos.world.character.Character`); see the module documentation.
mixin template ProcHandlers()
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import std.random : uniform01;
    import dmangos.world.auras : Aura, AuraType;
    import dmangos.world.classspells : CustomValues;
    import dmangos.world.aurahandlers : ProcFlag;
    import dmangos.world.procs : effectProcsOn, ppmChance, procEventMatches, ProcHit, takenProcFlags;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.spells : SpellProcEvent;
    import dmangos.world.unit : UnitKind, UnitRef;

    /// What a proc casts (`TriggerProccedSpell`): its spell, by this player, at a unit, with amounts of its own if any.
    static struct ProcCast
    {
        uint spell;
        ulong target;
        CustomValues custom;
        const(SpellInfo)* by; /// the aura that procced it (`m_triggeredByAuraSpell`)
    }

    private MonoTime[uint] procReadyAt; // an aura's spell -> when it may proc again (`spell_proc_event.Cooldown`)

    /// The procs of `flags` happening with `other` (see `procAuras`): each aura that procs on it rolls, then does
    /// what its effects do; the casts come last, once no aura is looked at any more.
    package void runProcs(uint flags, UnitRef other, const ProcHit hit)
    {
        static struct Rolled
        {
            Aura aura;
            ubyte effects;
            const(SpellProcEvent)* event;
        }

        Rolled[] rolled;
        const now = context.clock();
        const victim = (flags & takenProcFlags) != 0;
        foreach (aura; player.auras.list)
        {
            const event = context.data.spells.procEvent(aura.spell.id);
            const auraFlags = event !is null && event.procFlags ? event.procFlags : aura.spell.casting.procFlags;
            if (!procEventMatches(auraFlags, event, flags, hit))
                continue;
            // An aura does not proc on its own spell (but on its ticks).
            if (hit.spell !is null && hit.spell.id == aura.spell.id && !(auraFlags & ProcFlag.takeHarmfulPeriodic))
                continue;
            if (!victim && !procWeaponFits(aura.spell, hit))
                continue;
            ubyte effects;
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && effectProcsOn(aura.spell, i, event, hit))
                    effects |= 1 << i;
            if (!effects)
                continue;
            if (const at = aura.spell.id in procReadyAt)
                if (*at > now)
                    continue;
            float chance = event !is null && event.customChance ? event.customChance : aura.spell.casting.procChance;
            if (!victim && event !is null && event.ppmRate)
                chance = ppmChance(player.stats.attackTime[hit.hand < 3 ? hit.hand : 0], event.ppmRate);
            chance = spellMod(SpellModOp.chanceOfSuccess, aura.spell, chance);
            if (uniform01(map.random) * 100 >= chance)
                continue;
            rolled ~= Rolled(aura, effects, event);
        }
        ProcCast[] casts;
        Aura[] spent;
        foreach (r; rolled)
        {
            bool procced;
            const before = casts.length;
            foreach (i; 0 .. 3)
                if (r.effects & (1 << i))
                    procced |= procEffect(r.aura, i, hit, other, casts);
            foreach (ref c; casts[before .. $])
                c.by = r.aura.spell;
            if (!procced)
                continue;
            if (r.event !is null && r.event.cooldown)
                procReadyAt[r.aura.spell.id] = now + r.event.cooldown.msecs;
            if (r.aura.charges && --r.aura.charges == 0)
                spent ~= r.aura;
        }
        foreach (aura; spent)
            if (player.auras.list.canFind!(a => a is aura)) // (unless what it did took it away already)
                removeAura(aura);
        foreach (c; casts)
            if (const spell = context.data.spells.spell(c.spell))
            {
                procAuraSpell = c.by;
                scope (exit)
                    procAuraSpell = null;
                castCustom(spell, SpellTargets(TargetFlags.unit, c.target ? c.target : player.guid), c.custom);
            }
    }

    /// What effect `i` of an aura that procced does; true if it did anything (then a charge goes).
    private bool procEffect(Aura aura, size_t i, const ref ProcHit hit, UnitRef other, ref ProcCast[] casts)
    {
        switch (aura.type(i))
        {
        case AuraType.procTriggerSpell:
            auto c = ProcCast(aura.spell.triggerSpell[i], other ? other.combatGuid : player.guid);
            if (!classProcTrigger(aura, i, hit, other, c) || context.data.spells.spell(c.spell) is null)
                return false;
            casts ~= c;
            return true;
        case AuraType.dummy:
            return classDummyProc(aura, i, hit, other, casts);
        case AuraType.overrideClassScripts:
            return classScriptProc(aura, i, hit, other, casts);
        case AuraType.procTriggerDamage:
            return procDamage(aura, i, other);
        case AuraType.addFlatModifier, AuraType.addPctModifier: // their charges go as the spells they change are cast
            return false;
        case AuraType.modMeleeHaste: // Blade Flurry, Flurry
            return classHasteProc(aura, i, hit, other, casts);
        default:
            return aura.charges != 0; // a proc that only counts (`HandleNULLProc`): a charge goes
        }
    }

    /// `HandleProcTriggerDamageAuraProc`: the aura's amount of its school's damage at the other unit (Holy Shield,
    /// Blessing of Sanctuary), as its spell.
    private bool procDamage(Aura aura, size_t i, UnitRef other)
    {
        if (!other || !other.fighter.alive || aura.amount[i] <= 0)
            return false;
        final switch (other.kind)
        {
        case UnitKind.none:
            return false;
        case UnitKind.creature:
            spellDamage(aura.spell, other.creature, aura.amount[i], aura.spell.casting.school);
            return true;
        case UnitKind.player:
            spellDamageToPlayer(aura.spell, other.session, aura.amount[i]);
            return true;
        }
    }

    /**
     * Whether the weapon an aura needs (its spell's `EquippedItemClass`: a weapon of its subclasses for the hand
     * that struck, a shield) is in hand: Sword Specialization procs on sword swings only.
     */
    private bool procWeaponFits(const(SpellInfo)* spell, const ref ProcHit hit)
    {
        import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotOffhand, equipmentSlotRanged, ItemClass;

        enum uint noEquipRequirement = 0x00080000; // SPELL_ATTR_EX3_NO_PROC_EQUIP_REQUIREMENT
        if (spell.casting.attributesEx3 & noEquipRequirement)
            return true;
        if (spell.equippedItemClass != ItemClass.weapon && spell.equippedItemClass != ItemClass.armor)
            return true;
        const slot = spell.equippedItemClass == ItemClass.armor ? equipmentSlotOffhand
            : hit.hand == 1 ? equipmentSlotOffhand : hit.hand == 2 ? equipmentSlotRanged : equipmentSlotMainhand;
        const item = player.inventory.equipped(cast(ubyte) slot);
        if (item is null || item.proto is null || (item.maxDurability && item.durability == 0))
            return false;
        return item.proto.itemClass == spell.equippedItemClass
            && (spell.equippedItemSubClassMask == 0 || (spell.equippedItemSubClassMask & (1 << item.proto.subClass)));
    }
}

///
unittest
{
    import dmangos.world.spells : SpellProcEvent;

    SpellInfo fireball;
    fireball.casting.school = 2;
    fireball.casting.spellFamilyName = 3;
    fireball.casting.spellFamilyFlags = 1;
    auto crit = ProcHit(&fireball, ProcEx.criticalHit, 100);
    auto hit = ProcHit(&fireball, ProcEx.normalHit, 100);
    // Ignite: a fire spell's crit.
    const ignite = SpellProcEvent(1 << 2, 0, [0, 0, 0], 0, ProcEx.criticalHit);
    assert(procEventMatches(ProcFlag.dealHarmfulSpell, &ignite, ProcFlag.dealHarmfulSpell, crit));
    assert(!procEventMatches(ProcFlag.dealHarmfulSpell, &ignite, ProcFlag.dealHarmfulSpell, hit), "a crit only");
    SpellInfo frostbolt = fireball;
    frostbolt.casting.school = 4;
    auto frostCrit = ProcHit(&frostbolt, ProcEx.criticalHit, 100);
    assert(!procEventMatches(ProcFlag.dealHarmfulSpell, &ignite, ProcFlag.dealHarmfulSpell, frostCrit), "fire only");
    // No row: a hit or a crit that dealt damage; the aura's affect mask picks the spells.
    SpellInfo talent;
    talent.itemType[0] = 2;
    assert(procEventMatches(ProcFlag.dealHarmfulSpell, null, ProcFlag.dealHarmfulSpell, hit));
    assert(!effectProcsOn(&talent, 0, null, hit), "not a spell it affects");
    fireball.casting.spellFamilyFlags = 2;
    assert(effectProcsOn(&talent, 0, null, hit));
    auto swing = ProcHit(null, ProcEx.dodge);
    assert(!procEventMatches(ProcFlag.takeMeleeSwing, null, ProcFlag.takeMeleeSwing, swing), "a dodge is no hit");
    assert(spellProcFlags(fireball, false, false) == ProcFlag.dealHarmfulSpell);
    assert(spellProcFlags(fireball, false, true) == ProcFlag.takeHarmfulSpell);
    assert(ppmChance(3000, 7) == 35, "Seal of Command on a 3.0 speed weapon");
}
