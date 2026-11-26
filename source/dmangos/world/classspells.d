/**
 * The class abilities whose behaviour is code, not data (CMaNGOS's spell-family cases in `SpellEffects.cpp`,
 * `SpellAuras.cpp`, `Spell.cpp` and `UnitAuraProcHandler.cpp`; the class spell scripts bound by `spell_scripts`
 * are in `dmangos.scripts.spells`: Execute, Life Tap, Preparation, Vanish). Mixed into `dmangos.world.character.Character`; the cast pipeline calls in
 * at a few points: a cast's checks (`classCastCheck`), an effect's damage (`classSchoolDamage`), a dummy or script
 * effect (`classDummyEffect`), after the effects (`classAfterEffects`), an aura's amounts and its coming and going
 * (`classAuraValues`, `classAuraChanged`), and the procs (`classProcTrigger`, `classDummyProc`, `classScriptProc`).
 *
 * Auras replace each other as CMaNGOS's stacking rules have it for class spells: one aura of an exclusive kind from
 * each caster (a seal, a blessing, a paladin aura, an aspect, a sting, a curse, a mage armor: `exclusiveKind`), and a
 * helpful spell's higher rank over its lower one.
 *
 * By class:
 * $(UL
 * $(LI Warrior: Revenge and Overpower after a dodge, a parry or a block (the aura states and reactive timers),
 *   Bloodthirst's attack power damage and its healing aura, Deep Wounds' bleed of the weapon's damage, Sweeping
 *   Strikes' second blow, Retaliation (not from behind).)
 * $(LI Paladin: Judgement's aura state while a seal lasts, Seal of the Crusader's slower damage, Seal of Righteousness' holy damage
 *   by the weapon's speed, Judgement of Command (half unless stunned), Holy Shock (a heal or a blast), Holy Light
 *   and Flash of Light (their heals), Judgement of Light and of Wisdom (the striker healed or given mana),
 *   Forbearance, Hammer of Wrath under a fifth of health, Illumination's mana back, Blessing of Light.)
 * $(LI Warlock: Conflagrate (needs and consumes Immolate), Nightfall's Shadow Trance, Curse of Doom not at players.)
 * $(LI Mage: Cold Snap, Ignite, Combustion, Master of Elements, Shatter against frozen targets, Mana Shield's bonus,
 *   Improved Blizzard's chill.)
 * $(LI Rogue: Rupture's attack power, Ambush's bonus, Blade Flurry's second blow, Ruthlessness' and Seal Fate's
 *   points after the move; Vanish's
 *   Stealth (a script's call: `hostCastHighestRank`).)
 * $(LI Priest: Weakened Soul, Holy Nova's heal, Vampiric Embrace, Blessed Recovery, Touch of Weakness, Shadowguard.)
 * $(LI Druid: Ferocious Bite's extra energy, Rip's attack power, Swiftmend, Enrage, Frenzied Regeneration.)
 * $(LI Shaman: Lightning Shield's ranks, Flametongue (weapon and totem) by the weapon's speed, Healing Way,
 *   Stormstrike's charges.)
 * $(LI Hunter: Counterattack after a parry, Mongoose Bite after a dodge, Wyvern Sting's poison as it wakes.)
 * )
 * And every class's Add Target Trigger talents (Frostbite, Improved Scorch, Shadow Weaving, Relentless Strikes):
 * `targetTriggers`.
 */
module dmangos.world.classspells;

import dmangos.world.aurastate;
import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
import dmangos.world.defines : PlayerClass;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitKind, UnitRef;

/// `SpellFamilyName`.
enum SpellFamily : uint
{
    generic = 0,
    mage = 3,
    warrior = 4,
    warlock = 5,
    priest = 6,
    druid = 7,
    rogue = 8,
    hunter = 9,
    paladin = 10,
    shaman = 11,
    potion = 13,
}

/// A cast's own amounts for its effects (`CastCustomSpell`'s base points): `values[i]` for each effect with its bit in
/// `which`; the others as the spell has them.
struct CustomValues
{
    int[3] values;
    ubyte which;
    bool alwaysHits; /// `TRIGGERED_IGNORE_HIT_CALCULATION`: no hit roll (a judgement)
    const(SpellInfo)* by; /// the aura whose proc cast it (`m_triggeredByAuraSpell`), its missile's flight over too

    /// Just effect 0's.
    static CustomValues first(int value) pure nothrow @nogc @safe
    {
        return CustomValues([value, 0, 0], 1);
    }

    /// Whether effect `i` has one.
    bool has(size_t i) const pure nothrow @nogc @safe
    {
        return (which & (1 << i)) != 0;
    }
}

/// `SpellEntry::IsFitToFamily`: a spell of `family` (with one of `mask`'s bits, if given).
bool ofFamily(const(SpellInfo)* spell, SpellFamily family, ulong mask = 0) pure nothrow @nogc @safe
{
    return spell.casting.spellFamilyName == family && (mask == 0 || (spell.casting.spellFamilyFlags & mask) != 0);
}

/// `IsSealSpell`: a paladin's seal (every seal has one of these family flags, and no other paladin spell).
bool isSeal(const(SpellInfo)* spell) pure nothrow @nogc @safe
{
    return ofFamily(spell, SpellFamily.paladin, 0x000000000A000200);
}

/**
 * The kinds of aura of which a unit has one from each caster (CMaNGOS's `GetSpellSpecific`, `SPELL_SEAL` and the
 * rest): a new one puts out the other.
 */
enum ExclusiveKind : ubyte
{
    none,
    seal,
    blessing,
    paladinAura,
    aspect,
    sting,
    curse,
    mageArmor,
}

/// The exclusive kind of `spell`'s aura.
ExclusiveKind exclusiveKind(const(SpellInfo)* spell) pure nothrow @safe
{
    import dmangos.world.spellids : SpellEffect;

    enum uint dispelCurse = 2, dispelPoison = 4;
    switch (spell.casting.spellFamilyName)
    {
    case SpellFamily.paladin:
        if (isSeal(spell))
            return ExclusiveKind.seal;
        if (spell.casting.spellFamilyFlags & 0x10000000)
            return ExclusiveKind.blessing;
        if (spell.hasEffect(SpellEffect.applyAreaAuraParty))
            return ExclusiveKind.paladinAura;
        return ExclusiveKind.none;
    case SpellFamily.hunter:
        if (spell.casting.dispel == dispelPoison)
            return ExclusiveKind.sting;
        enum uint aspectOfTheWildIcon = 266;
        if ((spell.casting.spellFamilyFlags & 0x380000) || spell.casting.spellIconId == aspectOfTheWildIcon)
            return ExclusiveKind.aspect;
        return ExclusiveKind.none;
    case SpellFamily.warlock:
        return spell.casting.dispel == dispelCurse ? ExclusiveKind.curse : ExclusiveKind.none;
    case SpellFamily.mage:
        // Frost and Ice Armor (0x2000000), Mage Armor (0x10000000); not 0x80000, every frost spell's (Ice Barrier's).
        return spell.casting.spellFamilyFlags & 0x12000000 ? ExclusiveKind.mageArmor : ExclusiveKind.none;
    case SpellFamily.generic:
        enum uint aspectOfTheBeastIcon = 1510; // (the data leaves it out of the hunter's family)
        return spell.casting.spellIconId == aspectOfTheBeastIcon && spell.casting.name.length > 6
            && spell.casting.name[0 .. 6] == "Aspect" ? ExclusiveKind.aspect : ExclusiveKind.none;
    default:
        return ExclusiveKind.none;
    }
}

/**
 * The share of its main hand's damage a paladin keeps under Seal of the Crusader (`spell_seal_of_the_crusader`): its
 * attack speed is quicker by the seal's second amount, its damage less by as much, so its damage a second stays.
 */
float crusaderDamageFactor(A)(const(A)[] auras)
{
    float factor = 1;
    foreach (aura; auras)
        if (ofFamily(aura.spell, SpellFamily.paladin, 0x200) && isSeal(aura.spell) && (aura.effects & 0b10)
                && aura.amount[1] > -100)
            factor *= 100.0f / (100 + aura.amount[1]);
    return factor;
}

/// `Unit::CalculateLevelPenalty`: the share of the spell power a spell learned before level 20 gets (3.75% less a level).
float levelPenalty(const(SpellInfo)* spell) pure nothrow @nogc @safe
{
    return spell.spellLevel > 0 && spell.spellLevel < 20 ? 1.0f - (20.0f - spell.spellLevel) * 0.0375f : 1.0f;
}

/// The spell of `table` for `rank` (a rank of a talent or spell, as CMaNGOS lists them); 0 if none.
uint rankSpell(const(uint[2])[] table, uint rank) pure nothrow @nogc @safe
{
    foreach (ref row; table)
        if (row[0] == rank)
            return row[1];
    return 0;
}

/// Seal of Righteousness' ranks, and the holy damage each deals on a swing (`HandleDummyAuraProc`).
static immutable uint[2][] sealOfRighteousnessDamage = [[20154, 25742], [21084, 25741], [20287, 25740],
    [20288, 25739], [20289, 25738], [20290, 25737], [20291, 25736], [20292, 25735], [20293, 25713]];
/// Judgement of Light's ranks and the heal of its striker; Judgement of Wisdom's and the mana
/// (`spell_judgement_of_light_intermediate`, `spell_judgement_of_wisdom_intermediate`).
static immutable uint[2][] judgementOfLightHeal = [[20185, 20267], [20344, 20341], [20345, 20342], [20346, 20343]];
static immutable uint[2][] judgementOfWisdomMana = [[20186, 20268], [20354, 20352], [20355, 20353]];
/// Holy Shock's ranks: the blast at an enemy, the heal of a friend.
static immutable uint[2][] holyShockHurt = [[20473, 25912], [20929, 25911], [20930, 25902]];
static immutable uint[2][] holyShockHeal = [[20473, 25914], [20929, 25913], [20930, 25903]];
/// Ignite's ranks and the share of the crit it burns for a tick, in hundredths.
static immutable uint[2][] igniteShare = [[11119, 4], [11120, 8], [12846, 12], [12847, 16], [12848, 20]];
/// Deep Wounds' ranks and the share of the weapon's average damage it bleeds, in hundredths.
static immutable uint[2][] deepWoundsShare = [[12834, 20], [12849, 40], [12867, 60]];
/// Bloodthirst's ranks and the aura that heals on the next hits.
static immutable uint[2][] bloodthirstAura = [[23881, 23885], [23892, 23886], [23893, 23887], [23894, 23888]];
/// Lightning Shield's ranks and the damage of a charge (`HandleProcTriggerSpellAuraProc`: the data's is no spell).
static immutable uint[2][] lightningShieldDamage = [[324, 26364], [325, 26365], [905, 26366], [945, 26367],
    [8134, 26369], [10431, 26370], [10432, 26363]];
/// Holy Nova's ranks and its heal of the party (`Spell::Prepare`'s triggered spell).
static immutable uint[2][] holyNovaHeal = [[15237, 23455], [15430, 23458], [15431, 23459], [27799, 27803],
    [27800, 27804], [27801, 27805], [25331, 25329]];
/// Touch of Weakness' ranks and its curse on the striker.
static immutable uint[2][] touchOfWeaknessCurse = [[2652, 2943], [19261, 19249], [19262, 19251], [19264, 19252],
    [19265, 19253], [19266, 19254]];
/// Wyvern Sting's ranks and the poison that follows the sleep.
static immutable uint[2][] wyvernStingPoison = [[19386, 24131], [24132, 24134], [24133, 24135]];
/// Blessed Recovery's ranks and its heal.
static immutable uint[2][] blessedRecoveryHeal = [[27811, 27813], [27815, 27817], [27816, 27818]];
/// Judgement of Command's damage, by rank (CMaNGOS's `spell_judgement_of_command`; spell_template gives them no family).
static immutable uint[] judgementOfCommandDamage = [20467, 20963, 20964, 20965, 20966];
/// Shatter's override script numbers and the crit chance each adds against a frozen target (`spell_shatter_mage`).
static immutable uint[2][] shatterCrit = [[849, 10], [910, 20], [911, 30], [912, 40], [913, 50]];

/// Spells the precast of another's leaves behind (`Spell::Prepare`'s `AddPrecastSpell`).
enum : uint
{
    spellWeakenedSoul = 6788,
    spellForbearance = 25771,
    spellRecentlyBandaged = 11196,
}

/// `REACTIVE_TIMER_START`: how long a reactive state (a dodge, a parry, a block) lasts, in milliseconds.
enum int reactiveTime = 4000;

/**
 * A swing landed on `victim`, or did not (CMaNGOS's `Unit::ProcDamageAndSpell` aura state part): a player who
 * dodged, parried or blocked may use what needs it (Revenge, Overpower's warrior, Counterattack, Mongoose Bite)
 * for a while; a warrior whose swing was dodged gets a combo point on the dodger for Overpower.
 */
void swingReactions(UnitRef attacker, UnitRef victim, const ref MeleeDamage d)
{
    if (victim.kind == UnitKind.player)
        victim.session.swingDefended(d.outcome);
    if (attacker.kind == UnitKind.player && victim)
        attacker.session.swingDodgedBy(victim.combatGuid, d.outcome);
}

/// See the module documentation.
mixin template ClassSpells()
{
    import std.algorithm.comparison : min;
    import std.algorithm.searching : canFind;
    import std.random : uniform01;
    import dmangos.world.aurastate;
    import dmangos.world.auras : Aura, AuraSet, AuraType;
    import dmangos.world.classspells;
    import dmangos.world.combat : AttackType, MeleeHitOutcome;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : PlayerClass;
    import dmangos.world.procs : ProcEx, ProcHit;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spellcast : SpellCastResult, SpellMissInfo, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.unit : UnitKind, UnitRef;
    import dmangos.world.updatefields;

    // -----------------------------------------------------------------------
    // Aura states and the reactive timers
    // -----------------------------------------------------------------------

    private int[3] reactiveLeft; // ms left of each `ReactiveKind`

    private enum ReactiveKind
    {
        defense,
        hunterParry,
        overpower,
    }

    /// Whether this player has `state` now.
    package bool hasAuraState(AuraState state)
    {
        return (player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(state)) != 0;
    }

    /**
     * `Unit::ModifyAuraState`: `state` on or off. As one goes, so do the auras that needed it (their spell's
     * `CasterAuraState`).
     */
    package void modifyAuraState(AuraState state, bool on)
    {
        const before = player.values.get!UNIT_FIELD_AURASTATE, after = withAuraState(before, state, on);
        if (before == after)
            return;
        player.values.set!UNIT_FIELD_AURASTATE(after);
        if (!on)
            foreach (aura; player.auras.list.dup)
                if (aura.spell.casterAuraState == state)
                    removeAura(aura);
        flushPlayerChanges();
    }

    /// A swing at this player was dodged, parried or blocked: see `swingReactions`.
    package void swingDefended(MeleeHitOutcome outcome)
    {
        if (player is null)
            return;
        const classId = player.data.classId;
        if ((outcome == MeleeHitOutcome.dodge && classId != PlayerClass.rogue) // the rogue's Riposte is not this
                || (outcome == MeleeHitOutcome.parry && classId != PlayerClass.hunter) || outcome == MeleeHitOutcome.block)
            startReactive(ReactiveKind.defense);
        else if (outcome == MeleeHitOutcome.parry)
            startReactive(ReactiveKind.hunterParry);
    }

    /// This player's swing at `victim` had `outcome`: see `swingReactions`.
    package void swingDodgedBy(ulong victim, MeleeHitOutcome outcome)
    {
        if (player is null || outcome != MeleeHitOutcome.dodge || player.data.classId != PlayerClass.warrior)
            return;
        addComboPoints(victim, 1);
        reactiveLeft[ReactiveKind.overpower] = reactiveTime;
    }

    private void startReactive(ReactiveKind kind)
    {
        modifyAuraState(kind == ReactiveKind.hunterParry ? AuraState.hunterParry : AuraState.defense, true);
        reactiveLeft[kind] = reactiveTime;
    }

    /// Each tick: the reactive states' time (`Unit::UpdateReactives`: each ends four seconds on; all at death).
    package void updateReactives(int ms)
    {
        if (player is null)
            return;
        const dead = !player.alive;
        foreach (kind; 0 .. reactiveLeft.length)
        {
            if (reactiveLeft[kind] <= 0)
                continue;
            reactiveLeft[kind] = dead ? 0 : reactiveLeft[kind] - ms;
            if (reactiveLeft[kind] > 0)
                continue;
            final switch (cast(ReactiveKind) kind)
            {
            case ReactiveKind.defense:
                modifyAuraState(AuraState.defense, false);
                break;
            case ReactiveKind.hunterParry:
                modifyAuraState(AuraState.hunterParry, false);
                break;
            case ReactiveKind.overpower:
                if (player.data.classId == PlayerClass.warrior)
                    clearComboPoints();
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Casts with their own amounts (`CastCustomSpell`)
    // -----------------------------------------------------------------------

    package CustomValues pendingCustom; /// for the next `Casting` made (`castSpell`)
    package CustomValues effectCustom;  /// the cast whose effects are being done has these

    /// `spell` cast triggered at `targets`, its effects' amounts `custom`'s where it has them.
    package SpellCastResult castCustom(const(SpellInfo)* spell, SpellTargets targets, CustomValues custom)
    {
        pendingCustom = custom;
        scope (exit)
            pendingCustom = CustomValues.init;
        return castSpell(spell, targets, true, 0);
    }

    /// ditto, by id, at a unit (0: itself).
    package SpellCastResult castCustom(uint spellId, ulong target, CustomValues custom = CustomValues.init)
    {
        const spell = context.data.spells.spell(spellId);
        if (spell is null || player is null)
            return SpellCastResult.unknown;
        return castCustom(spell, SpellTargets(TargetFlags.unit, target ? target : player.guid), custom);
    }

    // -----------------------------------------------------------------------
    // Units and their auras
    // -----------------------------------------------------------------------

    /// The auras of a unit here.
    private AuraSet* aurasOf(UnitRef unit)
    {
        final switch (unit.kind)
        {
        case UnitKind.none:
            return null;
        case UnitKind.player:
            return unit.session.player is null ? null : &unit.session.player.auras;
        case UnitKind.creature:
            return &unit.creature.auras;
        }
    }

    /// The aura goes from `unit` (its effects end, everyone is told).
    private void takeAuraFrom(UnitRef unit, Aura aura)
    {
        final switch (unit.kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            return unit.session.removeAura(aura);
        case UnitKind.creature:
            unit.creature.loseAura(aura, map);
            map.flushObjectChanges(unit.creature);
            return;
        }
    }

    /// The first aura on `unit` from `caster` (0: anyone's) of a spell of `family` with a flag of `mask`, and an
    /// effect of `type`; null if none.
    private Aura familyAuraOn(UnitRef unit, SpellFamily family, ulong mask, AuraType type, ulong caster = 0)
    {
        if (auto set = aurasOf(unit))
            foreach (aura; set.list)
                if (ofFamily(aura.spell, family, mask) && aura.has(type) && (caster == 0 || aura.caster == caster))
                    return aura;
        return null;
    }

    /// A unit's health and its maximum.
    private uint[2] healthOf(UnitRef unit)
    {
        final switch (unit.kind)
        {
        case UnitKind.none:
            return [0, 0];
        case UnitKind.player:
            if (unit.session.player is null)
                return [0, 0];
            return [unit.session.player.values.get!UNIT_FIELD_HEALTH, unit.session.player.values.get!UNIT_FIELD_MAXHEALTH];
        case UnitKind.creature:
            return [unit.creature.values.get!UNIT_FIELD_HEALTH, unit.creature.values.get!UNIT_FIELD_MAXHEALTH];
        }
    }

    /// Whether `unit` is one this player may attack (an enemy, not a friend).
    private bool hostileTo(UnitRef unit)
    {
        return unit && unit.combatGuid != player.guid && canAttack(relatingNow(), unit.relating(), context.client);
    }

    /// The effect index of `spell`'s first effect that applies an aura of `type`; 3 if none.
    private static size_t effectOfAura(const(SpellInfo)* spell, AuraType type)
    {
        foreach (i; 0 .. 3)
            if (spell.casting.applyAuraName[i] == type)
                return i;
        return 3;
    }

    /// Whether `unit` is frozen (`Unit::isFrozen`: rooted or stunned by a frost spell: Frost Nova, Freeze).
    package static bool frozenForSpellCrit(UnitRef unit)
    {
        if (auto set = unit.auraSet)
            foreach (aura; set.list)
                if (aura.spell.casting.school == 4 && (aura.has(AuraType.modRoot) || aura.has(AuraType.modStun)))
                    return true;
        return false;
    }

    // -----------------------------------------------------------------------
    // Cast checks (`Spell::CheckCast`'s class cases and the class scripts' `OnCheckCast`)
    // -----------------------------------------------------------------------

    /**
     * What the class rules refuse of `spell` at `targets`: a warrior's Overpower without the dodge (its caster aura
     * state, as the client calls it), Conflagrate without the caster's Immolate on the target, Hammer of Wrath at
     * a target over a fifth of its health, Swiftmend without a Rejuvenation or Regrowth to consume, Curse of Doom at
     * a player, Power Infusion on someone under Arcane Power; a helpful spell its target is immune to (Power Word:
     * Shield under Weakened Soul, a second Divine Shield under Forbearance).
     */
    package SpellCastResult classCastCheck(const(SpellInfo)* spell, const ref SpellTargets targets)
    {
        auto target = targets.unit && targets.unit != player.guid ? map.unit(targets.unit) : UnitRef.of(this);
        // Only at the creature types it names (`TargetCreatureType`: Turn Undead at the undead, Hibernate at beasts and
        // dragonkin); a player is a humanoid.
        if (const types = spell.casting.targetCreatureType)
            if (target && target.combatGuid != player.guid)
            {
                const type = target.fighter.creatureType;
                if (type && !(types & (1u << (type - 1))))
                    return SpellCastResult.badTargets;
            }
        // Polymorph and the other spells bearing CANT_TARGET_TAPPED may use the caster's own party tap.
        enum uint cantTargetTapped = 0x40;
        if ((spell.attributesEx2 & cantTargetTapped) && target.kind == UnitKind.creature && target.creature.lootRecipient)
        {
            auto group = context.groups.of(player.guid);
            if (!target.creature.tappedBy(player.guid, group is null ? 0 : group.id))
                return SpellCastResult.cantCastOnTapped;
        }
        // Conflagrate
        if (ofFamily(spell, SpellFamily.warlock, 0x200) && spell.hasEffect(SpellEffect.schoolDamage))
            if (familyAuraOn(target, SpellFamily.warlock, 0x4, AuraType.periodicDamage, player.guid) is null)
                return SpellCastResult.targetAuraState;
        // Hammer of Wrath (its visual: CMaNGOS's way of telling it)
        enum uint hammerOfWrathVisual = 7250;
        if (spell.casting.spellVisual == hammerOfWrathVisual && spell.hasEffect(SpellEffect.schoolDamage))
        {
            if (!target || target.combatGuid == player.guid)
                return SpellCastResult.badImplicitTargets;
            const health = healthOf(target);
            if (health[0] > health[1] / 5)
                return SpellCastResult.badTargets;
        }
        // Swiftmend (`spell_swiftmend`)
        enum uint swiftmend = 18562;
        if (spell.id == swiftmend && familyAuraOn(target, SpellFamily.druid, 0x50, AuraType.periodicHeal) is null)
            return SpellCastResult.targetAuraState;
        // Curse of Doom (`spell_curse_of_doom`)
        enum uint curseOfDoom = 603;
        if (spell.id == curseOfDoom && target.kind == UnitKind.player)
            return SpellCastResult.badTargets;
        // Power Infusion (`spell_power_infusion`): not with Arcane Power.
        enum uint powerInfusion = 10060, arcanePower = 12042;
        if (spell.id == powerInfusion)
            if (auto set = aurasOf(target))
                if (set.find(arcanePower) !is null)
                    return SpellCastResult.auraBounced;
        // A helpful spell at someone immune to its mechanic (Weakened Soul, Forbearance: `IsImmuneToSpell`).
        if (target && !hostileTo(target) && spell.casting.mechanic
                && target.fighter.immune.toMechanic(spell.casting.mechanic))
            return SpellCastResult.targetAuraState;
        return SpellCastResult.ok;
    }

    // -----------------------------------------------------------------------
    // Effects
    // -----------------------------------------------------------------------

    /**
     * A school damage effect's amount by the class rules (`EffectSchoolDMG`): Bloodthirst is a share of the attack
     * power; Shield Slam adds the shield's block value; Ferocious Bite turns the energy left into damage, and the
     * attack power by the combo points; Conflagrate consumes the Immolate it needs.
     */
    package int classSchoolDamage(const(SpellInfo)* spell, size_t i, ulong targetGuid, int damage)
    {
        import dmangos.world.defines : Power;

        // Bloodthirst
        if (ofFamily(spell, SpellFamily.warrior, 0x2000000) && spell.casting.spellIconId == 38)
            return damage * player.stats.attackPower / 100;
        // Shield Slam (the same family flag): its damage and the shield's block value.
        if (ofFamily(spell, SpellFamily.warrior, 0x2000000) && spell.casting.spellIconId == 413)
            return damage + cast(int) player.fighter.shieldBlock;
        // Ferocious Bite
        enum uint ferociousBiteVisual = 6587;
        if (ofFamily(spell, SpellFamily.druid, 0x800000) && spell.casting.spellVisual == ferociousBiteVisual)
        {
            const energy = cast(int) player.values.get!UNIT_FIELD_POWER1(Power.energy);
            damage += cast(int)(energy * spell.casting.dmgMultiplier[i]);
            player.modifyPower(Power.energy, -energy);
            damage += cast(int)(player.stats.attackPower * 0.03f * castCombo);
            return damage;
        }
        // Judgement of Command (`spell_judgement_of_command`): half, unless its target is stunned. Its damage spells
        // (what the judgement's dummy names) are of no family.
        if (judgementOfCommandDamage.canFind(spell.id))
        {
            auto target = map.unit(targetGuid);
            if (auto set = aurasOf(target))
                if (!set.has(AuraType.modStun))
                    return damage / 2;
            return damage;
        }
        // Conflagrate
        if (ofFamily(spell, SpellFamily.warlock, 0x200))
        {
            auto target = map.unit(targetGuid);
            if (auto immolate = familyAuraOn(target, SpellFamily.warlock, 0x4, AuraType.periodicDamage, player.guid))
                takeAuraFrom(target, immolate);
        }
        return damage;
    }

    /**
     * A dummy or script effect of a class spell (`EffectDummy`, `EffectScriptEffect`): what it does; true if it is
     * one (the spell's scripts then do not run).
     */
    package bool classDummyEffect(const(SpellInfo)* spell, size_t i, ulong targetGuid, int value, uint castItemEntry)
    {
        auto target = map.unit(targetGuid);
        const outer = castingFor;
        castingFor = spell;
        scope (exit)
            castingFor = outer;
        // Shadowguard (`spell_shadowguard`): the charge's shadow damage, of the rank of the aura that procced.
        static immutable uint[2][] shadowguardDamage = [[18137, 28377], [19308, 28378], [19309, 28379], [19310, 28380],
            [19311, 28381], [19312, 28382]];
        enum uint shadowguard = 28376;
        if (spell.id == shadowguard)
        {
            if (const by = procAuraSpell !is null ? procAuraSpell : effectCustom.by)
                if (const damage = rankSpell(shadowguardDamage, by.id))
                    castCustom(damage, targetGuid);
            return true;
        }
        if (physicalClassDummy(spell, i, target, value)) // the warrior's, rogue's, hunter's (dmangos.world.physicalclasses)
            return true;
        if (petAuraDummy(spell, targetGuid)) // Soul Link (dmangos.world.petauras)
            return true;
        switch (cast(SpellFamily) spell.casting.spellFamilyName)
        {
        case SpellFamily.mage:
            enum uint coldSnap = 12472;
            if (spell.id == coldSnap)
            {
                // Every frost spell of the mage's with a cooldown is ready at once.
                resetCooldowns(SpellFamily.mage, 1 << 4, 0);
                return true;
            }
            return false;
        case SpellFamily.priest:
            enum uint touchOfWeakness = 28598;
            const by = procAuraSpell !is null ? procAuraSpell : effectCustom.by;
            if (spell.id == touchOfWeakness && by !is null)
            {
                if (const curse = rankSpell(touchOfWeaknessCurse, by.id))
                    castCustom(curse, targetGuid);
                return true;
            }
            return false;
        case SpellFamily.druid:
            enum uint enrage = 5229, enrageArmor = 25503, direBearForm = 9634;
            if (spell.id == enrage)
            {
                // Less armor while enraged: 16% in Dire Bear Form, 27% in Bear Form: 25503's second effect (its first
                // is none).
                const reduction = player.auras.find(direBearForm) !is null ? -16 : -27;
                castCustom(enrageArmor, player.guid, CustomValues([0, reduction, 0], 0b10));
                // "The druid is considered in combat for the duration" (its tooltip): no rage lost meanwhile.
                import core.time : msecs;
                import dmangos.world.spellcast : duration;

                enterCombatFor(duration(*spell, context.client, player.data.level).msecs);
                return true;
            }
            return false;
        case SpellFamily.warlock:
            return createHealthstone(spell);
        case SpellFamily.paladin:
            return paladinDummy(spell, i, target, value);
        case SpellFamily.shaman:
            return flametongue(spell, target, value);
        default:
            return false;
        }
    }

    /// Judgement, Holy Shock, Judgement of Command, Holy Light, Flash of Light.
    private bool paladinDummy(const(SpellInfo)* spell, size_t i, UnitRef target, int value)
    {
        enum uint holyShockIcon = 156, judgementOfCommandIcon = 561, holyLightIcon = 70, flashOfLightIcon = 242;
        enum uint holyLightHeal = 19968, flashOfLightHeal = 19993, judgement = 20271;
        if (!target)
            return false;
        if (spell.id == judgement)
        {
            // `spell_judgement`: the seal on goes, and its judgement (its third effect's amount names it) strikes,
            // without a hit roll.
            if (!target.alive)
                return true;
            foreach (seal; player.auras.list)
            {
                if (!isSeal(seal.spell) || seal.caster != player.guid || !(seal.effects & 0b100)
                        || seal.type(2) != AuraType.dummy)
                    continue;
                const judged = seal.spell.simpleValue(2);
                if (judged <= 1)
                    continue;
                removeAura(seal);
                auto custom = CustomValues.init;
                custom.alwaysHits = true;
                castCustom(cast(uint) judged, target.combatGuid, custom);
                break;
            }
            return true;
        }
        switch (spell.casting.spellIconId)
        {
        case holyShockIcon:
            // A blast at an enemy, a heal on a friend.
            if (const shock = rankSpell(hostileTo(target) ? holyShockHurt : holyShockHeal, spell.id))
                castCustom(shock, target.combatGuid);
            return true;
        case judgementOfCommandIcon:
            // Its amount is the spell that strikes.
            if (spell.effect[i] == SpellEffect.dummy && value > 0)
                castCustom(cast(uint) value, target.combatGuid);
            return true;
        case holyLightIcon, flashOfLightIcon:
            // The heal itself, of the amount rolled; the spell for Illumination's mana back.
            if (spell.effect[i] != SpellEffect.scriptEffect || !target.alive)
                return false;
            // Holy Light's first three ranks heal by spells of their own, whose share of the healing power is less by
            // their level (Blizzard's coefficients: 0.205, 0.339, 0.554; the rest 19968's 0.714).
            static immutable uint[2][] holyLightHeals = [[635, 19982], [639, 19981], [647, 19980]];
            uint heal = spell.casting.spellIconId == holyLightIcon ? holyLightHeal : flashOfLightHeal;
            if (const own = rankSpell(holyLightHeals, spell.id))
                heal = own;
            castCustom(heal, target.combatGuid, CustomValues([value, cast(int) spell.id, 0], 0b11));
            return true;
        default:
            return false;
        }
    }

    /**
     * Flametongue Weapon's and Flametongue Totem's procs: fire damage by the weapon's speed (and for the weapon, a
     * share of the spell power), dealt by their attack spell.
     */
    private bool flametongue(const(SpellInfo)* spell, UnitRef target, int value)
    {
        import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotOffhand;

        enum ulong weaponProc = 0x200000, totemProc = 0x400000000;
        enum uint weaponAttack = 10444, totemAttack = 16368;
        const weapon = ofFamily(spell, SpellFamily.shaman, weaponProc), totem = ofFamily(spell, SpellFamily.shaman, totemProc);
        if (!weapon && !totem)
            return false;
        if (!target)
            return true;
        const item = player.inventory.equipped(procHand == AttackType.offHand ? equipmentSlotOffhand : equipmentSlotMainhand);
        if (item is null || item.proto is null)
            return true;
        const speed = item.proto.details.delay / 1000.0f;
        int total;
        // The spell power is the attack spell's own (Blizzard's 0.1 for the weapon's, none for the totem's).
        total = cast(int)(value * 0.01f * speed);
        castCustom(weapon ? weaponAttack : totemAttack, target.combatGuid, CustomValues.first(total));
        return true;
    }

    // -----------------------------------------------------------------------
    // Druid: forms
    // -----------------------------------------------------------------------

    /// A passive a class rule gives in some forms: its spell, whether it is had, its amounts, its forms (0: its `Stances`).
    static struct FormPassive
    {
        uint spell;
        bool known;
        int[3] values;
        uint forms;
    }

    /**
     * The passives a druid's talents give in its forms (their own spells are dummies), Moonkin Form's party aura and
     * Bear Form's threat: Leader of the Pack's party aura
     * (17007: 24932, 3% crit), Predatory Strikes' attack power (16972, 16974, 16975: 24868, by 50, 100, 150% of the
     * druid's level; the tooltip: "Increases your melee attack power in Cat, Bear and Dire Bear Forms by 150% of your
     * level").
     */
    package FormPassive[] classFormPassives()
    {
        if (player.data.classId != PlayerClass.druid)
            return null;
        enum uint leaderOfThePack = 17007, packAura = 24932, predatoryStrikesAttackPower = 24868, bearThreat = 21178;
        enum uint bearForms = 1u << (5 - 1) | 1u << (8 - 1);
        static immutable uint[] predatoryStrikes = [16972, 16974, 16975];
        FormPassive[] passives;
        if (const pack = context.data.spells.spell(packAura))
            passives ~= FormPassive(packAura, player.knowsSpell(leaderOfThePack), [pack.simpleValue(0), 0, 0]);
        int share;
        foreach (rank; predatoryStrikes)
            if (player.knowsSpell(rank))
                if (const talent = context.data.spells.spell(rank))
                    share = talent.simpleValue(0);
        passives ~= FormPassive(predatoryStrikesAttackPower, share != 0,
            [cast(int)(player.data.level * share / 100), 0, 0]);
        // Heart of the Wild's forms (its tooltip: "while in Bear or Dire Bear Form your Stamina is increased by 20% and
        // while in Cat Form your Strength"): its effects of no amount, 24899 and 24900, by the talent's.
        static immutable uint[] heartOfTheWild = [17003, 17004, 17005, 17006, 24894];
        enum uint heartBear = 24899, heartCat = 24900;
        int heart;
        foreach (rank; heartOfTheWild)
            if (player.knowsSpell(rank))
                if (const talent = context.data.spells.spell(rank))
                    heart = talent.simpleValue(0);
        passives ~= FormPassive(heartBear, heart != 0, [heart, 0, 0]);
        passives ~= FormPassive(heartCat, heart != 0, [heart, 0, 0]);
        // Travel Form's speed (5419, of no `Stances`): Travel Form's.
        enum uint travelSpeed = 5419;
        if (const travel = context.data.spells.spell(travelSpeed))
            passives ~= FormPassive(travelSpeed, player.knowsSpell(travelSpeed), [travel.simpleValue(0), 0, 0], 1u << (3 - 1));
        // Moonkin Aura (24907: the party's 3% spell crit), which a druid learns with its Balance skill, not passive.
        enum uint moonkinAura = 24907;
        if (const aura = context.data.spells.spell(moonkinAura))
            passives ~= FormPassive(moonkinAura, player.knowsSpell(moonkinAura), [aura.simpleValue(0), 0, 0]);
        // Bear Form (Passive2)'s 30% more threat, of no `Stances`: the bear forms' (Feral Instinct adds to it).
        if (const threat = context.data.spells.spell(bearThreat))
            passives ~= FormPassive(bearThreat, player.knowsSpell(bearThreat), [effectMod(threat, 0, threat.simpleValue(0)),
                0, 0], bearForms);
        return passives;
    }

    /**
     * A druid took a form (`form`, `ShapeshiftForm`): its rage or energy starts at none; Furor's chance (17056 .. 17061: 20% a rank) of 10 rage in Bear or
     * Dire Bear Form (17057), of 40 energy in Cat Form (17099).
     */
    package void classShapeshifted(ubyte form)
    {
        enum ubyte cat = 1, bear = 5, direBear = 8;
        enum uint furorRage = 17057, furorEnergy = 17099;
        static immutable uint[] furor = [17056, 17058, 17059, 17060, 17061];
        if (player.data.classId != PlayerClass.druid || (form != cat && form != bear && form != direBear))
            return;
        // A form's own power starts at none (what made "powershifting" with Furor worth it).
        import dmangos.world.defines : Power;

        player.modifyPower(form == cat ? Power.energy : Power.rage,
            -cast(int) player.values.get!UNIT_FIELD_POWER1(form == cat ? Power.energy : Power.rage));
        foreach (aura; player.auras.list)
            if (furor.canFind(aura.spell.id))
            {
                if (uniform01(map.random) * 100 < aura.amount[0])
                    castCustom(form == cat ? furorEnergy : furorRage, player.guid);
                break;
            }
    }

    package AttackType procHand; /// the hand whose swing set the current item procs off
    /// The spell whose dummy or script effect is under way (what it casts spends its charged modifiers as its own).
    package const(SpellInfo)* castingFor;

    /**
     * The player's cooldowns end on its spells of `family` that have one (and of a school in `schoolMask`, if
     * given), but `except` (`Player::RemoveSomeCooldown`): Cold Snap, Preparation. How many ended.
     */
    package uint resetCooldowns(uint family, uint schoolMask, uint except)
    {
        // The spells cooling down by their own time or their category's (Ice Block has only a category's).
        bool[uint] cooling;
        foreach (id; spellReadyAt.keys)
            cooling[id] = true;
        foreach (id; cooldownCategory.keys)
            cooling[id] = true;
        uint ended;
        foreach (id; cooling.keys)
        {
            const spell = context.data.spells.spell(id);
            if (spell is null || id == except || spell.casting.spellFamilyName != family)
                continue;
            if (schoolMask && !(schoolMask & (1u << spell.casting.school)))
                continue;
            if ((spell.recoveryTime == 0 && spell.categoryRecoveryTime == 0) || spellIsReady(id))
                continue;
            clearCooldownFor(id);
            ++ended;
        }
        return ended;
    }

    /**
     * After the effects of `spell` (`hit`: the targets it reached): Bloodthirst's aura, Holy Nova's heal, what is
     * cast before the effects in CMaNGOS (Weakened Soul, Forbearance, Recently Bandaged: here after them, which the
     * immunities they give would otherwise refuse), a melee ability dodged (Overpower's point), and procs held for
     * after a finishing move (Ruthlessness, Seal Fate).
     */
    package void classAfterEffects(const(SpellInfo)* spell, const(ulong)[] hit, const(ulong)[] dodgedBy)
    {
        enum uint mechanicBandage = 16, mechanicInvulnerability = 25;
        if (hit.length)
        {
            if (const aura = rankSpell(bloodthirstAura, spell.id))
                castCustom(aura, player.guid);
            if (const heal = rankSpell(holyNovaHeal, spell.id)) // (its caster is among them, an enemy near or not)
                castCustom(heal, player.guid);
        }
        uint precast;
        if (ofFamily(spell, SpellFamily.priest, 0x1)) // Power Word: Shield
            precast = spellWeakenedSoul;
        else if (spell.casting.mechanic == mechanicInvulnerability && spell.id != spellForbearance
                && (spell.casting.spellFamilyName == SpellFamily.generic || spell.casting.spellFamilyName == SpellFamily.paladin))
            precast = spellForbearance; // Divine Shield, Divine Protection, Blessing of Protection
        else if (spell.casting.mechanic == mechanicBandage && spell.casting.spellFamilyName == SpellFamily.generic)
            precast = spellRecentlyBandaged;
        if (precast)
            foreach (target; hit)
                castCustom(precast, target);
        foreach (target; dodgedBy)
            swingDodgedBy(target, MeleeHitOutcome.dodge);
        // (a missile's targets when it lands: `missileLanded`)
        ulong[] reached;
        foreach (target; hit)
            if (!missileOnTheWay(spell, target))
                reached ~= target;
        targetTriggers(spell, reached);
        foreach (target; hit)
            if (spell.hasEffect(SpellEffect.schoolDamage))
                pyroclasm(spell, target); // Hellfire's ticks, Soul Fire
        auto held = heldProcs;
        heldProcs = null;
        foreach (c; held)
            castCustom(c.spell, c.target, c.custom);
    }

    private ProcCast[] heldProcs; // procs that wait for the end of the cast (`Spell::AddTriggeredSpell`)

    /**
     * `Spell::ProcSpellAuraTriggers`: each of the caster's Add Target Trigger auras that affects `spell` (Frostbite,
     * Improved Scorch, Shadow Weaving, Relentless Strikes, Initiative) may cast its spell at each target hit, by its
     * amount as a chance (and its points a combo point).
     */
    package void targetTriggers(const(SpellInfo)* spell, const(ulong)[] hit, UnitRef remote = UnitRef.init)
    {
        import dmangos.world.spellmods : affects;

        enum uint relentlessStrikesEnergy = 14181;
        ProcCast[] casts;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
            {
                if (!(aura.effects & (1 << k)) || aura.type(k) != AuraType.addTargetTrigger || !aura.spell.triggerSpell[k]
                        || !affects(aura, k, *spell))
                    continue;
                const trigger = aura.spell.triggerSpell[k];
                // Relentless Strikes restores the rogue's own energy even if the finisher killed its target.
                const returnsEnergy = trigger == relentlessStrikesEnergy;
                const chance = aura.amount[k] + aura.spell.casting.pointsPerComboPoint[k] * castCombo;
                foreach (target; hit)
                {
                    // Once for each it struck: the caster, an effect of its own on it (Eviscerate's), only if it
                    // struck no other (Relentless Strikes' "20% chance per combo point", not twice that).
                    if (target == player.guid && hit.canFind!(t => t != player.guid))
                        continue;
                    auto unit = target == player.guid ? UnitRef.of(this) : map.unit(target);
                    if (!unit && target == remote.combatGuid)
                        unit = remote;
                    if (unit && (unit.alive || (returnsEnergy && player.alive)) && uniform01(map.random) * 100 < chance)
                        casts ~= ProcCast(trigger, returnsEnergy ? player.guid : target);
                }
            }
        foreach (c; casts)
            if (remote.replica !is null && c.target == remote.combatGuid)
            {
                if (const trigger = context.data.spells.spell(c.spell))
                    castProcAtReplica(trigger, remote.replica, c.custom);
            }
            else
                castCustom(c.spell, c.target, c.custom);
    }

    /**
     * An effect's value after its index's modifiers (`effectMod`), by the class rules. The slows' talents ("reduces the
     * target's speed by an additional", "increases the speed reduction of your Curse of Exhaustion") are modifiers of
     * the second effect: the speed of a chill (Chilled's), but the damage of Frostbolt and Cone of Cold (their slows
     * are their first), and nothing of Curse of Exhaustion (its slow is its only effect). Their amount goes to the
     * spell's slow, wherever it is, and never to its damage: Permafrost, Improved Curse of Exhaustion, Amplify Curse.
     */
    package int classEffectMod(const(SpellInfo)* spell, size_t i, int value)
    {
        import dmangos.world.spellmods : affects, SpellModOp;

        static immutable uint[] slowTalents = [11175, 18310, 18288]; // (their first ranks)
        if (spell.casting.spellFamilyName != SpellFamily.mage && spell.casting.spellFamilyName != SpellFamily.warlock)
            return value;
        const slow = spell.casting.applyAuraName[i] == AuraType.modDecreaseSpeed;
        foreach (aura; player.auras.list)
        {
            const first = chainFirstRank(aura.spell.id);
            if (!slowTalents.canFind(first ? first : aura.spell.id))
                continue;
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.misc(k) == SpellModOp.effect2 && affects(aura, k, *spell))
                {
                    if (i == 1 && !slow)
                        value -= aura.amount[k]; // (the modifier of index 1 added it to the damage)
                    else if (i != 1 && slow)
                        value += aura.amount[k];
                }
        }
        // Improved Enslave Demon: "Reduces the Attack Speed and Casting Speed penalty": its casting speed is a
        // modifier of the third effect (Enslave Demon's casting speed), its attack speed one its data names 24 (no
        // effect index): it goes to the attack speed (`MOD_MELEE_HASTE`) effect.
        enum uint improvedEnslaveDemon = 18821;
        enum int attackSpeedOp = 24;
        if (spell.casting.applyAuraName[i] == AuraType.modMeleeHaste)
            foreach (aura; player.auras.list)
                if (chainFirstRank(aura.spell.id) == improvedEnslaveDemon)
                    foreach (k; 0 .. 3)
                        if ((aura.effects & (1 << k)) && aura.misc(k) == attackSpeedOp && affects(aura, k, *spell))
                            value += aura.amount[k];
        return value;
    }

    /**
     * The amounts of an aura of `spell` about to go on (`Aura` creation's class cases): Rip and Rupture take a share
     * of the attack power for each combo point (at most four, and three); Mana Shield half the spell power.
     */
    package void classAuraValues(const(SpellInfo)* spell, ref int[3] values)
    {
        physicalClassAuraValues(spell, values); // Pathfinding (dmangos.world.physicalclasses)
        foreach (i; 0 .. 3)
        {
            const type = spell.casting.applyAuraName[i];
            if (type == AuraType.periodicDamage && castCombo)
            {
                if (ofFamily(spell, SpellFamily.druid, 0x800000)) // Rip
                    values[i] += player.stats.attackPower * (castCombo > 4 ? 4 : castCombo) / 100;
                else if (ofFamily(spell, SpellFamily.rogue, 0x100000)) // Rupture
                    values[i] += player.stats.attackPower * (castCombo > 3 ? 3 : castCombo) / 100;
            }
        }
    }

    /**
     * An aura on this player begins (`apply`) or ends: the auras it replaces go (`replacedBy`); a seal lets it judge
     * (`AURA_STATE_JUDGEMENT`) while one lasts.
     */
    package void classAuraChanged(Aura aura, bool apply)
    {
        // Shadow Trance (Nightfall's): "the casting time of your next Shadow Bolt"; its data gives it no charge to be
        // spent by it, as Presence of Mind's has.
        enum uint shadowTrance = 17941;
        if (apply && aura.spell.id == shadowTrance && aura.charges == 0)
            aura.charges = 1;
        if (!apply)
        {
            spiritOfRedemptionEnded(aura);
            possessedSummonEnded(aura);
        }
        if (apply)
            foreach (other; replacedBy(player.auras, aura))
                removeAura(other);
        if (!isSeal(aura.spell) || aura.caster != player.guid)
            return;
        if (apply)
            modifyAuraState(AuraState.judgement, true);
        else if (!player.auras.list.canFind!(a => a !is aura && isSeal(a.spell)))
            modifyAuraState(AuraState.judgement, false);
    }

    /// An aura of this player's went on `target`: the auras it replaces there go (a sting, a curse).
    package void classCreatureAuraApplied(Creature target, Aura aura)
    {
        foreach (other; replacedBy(target.auras, aura))
            takeAuraFrom(map.unitOf(target), other);
    }

    /**
     * The auras of `set` that `aura`, just on, replaces (CMaNGOS's stacking rules for class spells): another of its
     * exclusive kind from its caster (a seal, a blessing, an aspect, a sting, a curse...), and another rank of a
     * helpful spell (Power Word: Fortitude over a lower one, whoever cast it).
     */
    private Aura[] replacedBy(ref AuraSet set, Aura aura)
    {
        if (aura.passive)
            return null;
        const kind = exclusiveKind(aura.spell);
        const first = chainFirstRank(aura.spell.id);
        Aura[] replaced;
        foreach (other; set.list)
        {
            if (other is aura || other.passive)
                continue;
            if (kind != ExclusiveKind.none && exclusiveKind(other.spell) == kind && other.caster == aura.caster)
                replaced ~= other;
            else if (aura.positive && other.positive && other.spell.id != aura.spell.id && first
                    && chainFirstRank(other.spell.id) == first)
                replaced ~= other;
        }
        return replaced;
    }

    /// The first rank of `id`'s chain (itself if it is the first); 0 if it is in none.
    private uint chainFirstRank(uint id)
    {
        if (const node = id in context.data.spells.chains)
            return node.first ? node.first : id;
        return 0;
    }

    /// This player's aura on `target` ended: Wyvern Sting's sleep leaves its poison.
    package void classCreatureAuraLost(Creature target, Aura aura)
    {
        scorpidStingLost(target, aura); // Improved Scorpid Sting's stamina with it (dmangos.world.physicalclasses)
        if (!target.alive || !ofFamily(aura.spell, SpellFamily.hunter, 0x10000) || !aura.has(AuraType.modStun))
            return;
        if (const poison = rankSpell(wyvernStingPoison, aura.spell.id))
            castCustom(poison, target.guid);
    }

    /// The factor of a weapon ability's fixed bonus instead of its weapon percentage (`EffectWeaponDmg`): Ambush's.
    package float classWeaponBonusFactor(const(SpellInfo)* spell)
    {
        return ofFamily(spell, SpellFamily.rogue, 0x200) ? 2.5f : 0;
    }

    /**
     * A heal's amount by the class rules: Swiftmend consumes the shortest Rejuvenation or Regrowth on its target for
     * all its ticks at once (`EffectHeal`); Blessing of Light adds to Holy Light and Flash of Light, Healing Way to
     * Healing Wave (`spell_blessing_of_light`, `spell_healing_way`).
     */
    package int classHeal(const(SpellInfo)* spell, UnitRef target, int value)
    {
        import dmangos.world.spellcast : castTime, duration;

        enum uint swiftmend = 18562, healingWay = 29203;
        auto set = aurasOf(target);
        if (set is null)
            return value;
        if (spell.id == swiftmend)
        {
            Aura shortest;
            foreach (aura; set.list)
                if (ofFamily(aura.spell, SpellFamily.druid, 0x50) && aura.has(AuraType.periodicHeal)
                        && (shortest is null || aura.duration < shortest.duration))
                    shortest = aura;
            if (shortest is null)
                return value;
            const i = effectOfAura(shortest.spell, AuraType.periodicHeal);
            const period = shortest.spell.casting.amplitude[i];
            const ticks = period ? duration(*shortest.spell, context.client, shortest.casterLevel) / period : 0;
            value += shortest.amount[i] * ticks;
            takeAuraFrom(target, shortest);
            return value;
        }
        if (spell.hasEffect(imported!"dmangos.world.spellids".SpellEffect.heal))
            classHealed(spell, target); // (its initial heal; the ticks: `periodicHeal`)
        foreach (aura; set.list)
        {
            // Blessing of Light: effect 0 for Holy Light's heal, 1 for Flash of Light's, as healing power ("up to"):
            // the heal's share of it (Blizzard's coefficient).
            if (ofFamily(aura.spell, SpellFamily.paladin, 0x10000000) && aura.has(AuraType.dummy))
            {
                enum ulong holyLightHeal = 0x4000, flashOfLightHeal = 0x2000; // 19968 (19980..19982), 19993
                const which = ofFamily(spell, SpellFamily.paladin, holyLightHeal) ? 0
                    : ofFamily(spell, SpellFamily.paladin, flashOfLightHeal) ? 1 : 3;
                if (which < 3 && (aura.effects & (1 << which)))
                {
                    import dmangos.world.spellcast : bonusCoefficient;

                    value += cast(int)(aura.amount[which] * bonusCoefficient(*spell, 0, context.client, player.data.level));
                }
            }
            else if (aura.spell.id == healingWay && ofFamily(spell, SpellFamily.shaman, 0x40)) // by its stacks (3 at most)
                value = value * (aura.amount[0] * cast(int) aura.stacks + 100) / 100;
        }
        return value;
    }

    /**
     * This player's heal or heal over time (`spell`) landed on `target`, a tick of it too: Regrowth with the
     * Dreamwalker Raiment's six pieces (their override class script 4537, 28744: "Your initial cast and Regrowth ticks
     * will increase the maximum health of your target by up to 50, stacking up to 7 times") gives Blessing of the Claw
     * (28750).
     */
    package void classHealed(const(SpellInfo)* spell, UnitRef target)
    {
        enum int dreamwalkerRegrowth = 4537;
        enum uint blessingOfTheClaw = 28750;
        if (!ofFamily(spell, SpellFamily.druid, 0x40) || !target || !target.alive)
            return;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.overrideClassScripts
                        && aura.misc(i) == dreamwalkerRegrowth)
                {
                    castCustom(blessingOfTheClaw, target.combatGuid);
                    return;
                }
    }

    /**
     * A tick of this player's persistent area (`spell`) hurt `target`: Blizzard chills it with Improved Blizzard
     * (`spell_blizzard`: the talent's override script names its rank).
     */
    package void classAreaTick(const(SpellInfo)* spell, UnitRef target)
    {
        static immutable uint[2][] improvedBlizzardChill = [[836, 12484], [988, 12485], [989, 12486]];
        if (target && target.alive)
            pyroclasm(spell, target.combatGuid, target.replica); // Rain of Fire
        if (!ofFamily(spell, SpellFamily.mage, 0x80) || !target || !target.alive)
            return;
        uint chill;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.overrideClassScripts)
                    if (const ranked = rankSpell(improvedBlizzardChill, cast(uint) aura.misc(i)))
                        chill = ranked;
        if (chill)
            castAreaTickTrigger(chill, target.combatGuid, target.replica);
        arcaneConcentrationTick();
    }

    private void castAreaTickTrigger(uint spellId, ulong target,
        imported!"dmangos.world.replication".Replica replica)
    {
        if (replica is null)
            castCustom(spellId, target);
        else if (const spell = context.data.spells.spell(spellId))
            castProcAtReplica(spell, replica, CustomValues.init);
    }

    /**
     * Whether this player's ward sends `spell` back (`SPELL_AURA_REFLECT_SPELLS_SCHOOL`, of the spell's school): Fire
     * Ward's and Frost Ward's amount is none, the chance their talents' (Improved Fire Ward's, Frost Warding's dummy
     * effect: "gives your Frost Ward a 20% chance to reflect Frost spells and effects while active").
     */
    package bool reflectsSpell(const(SpellInfo)* spell)
    {
        enum uint magic = 1; // SPELL_DAMAGE_CLASS_MAGIC
        if (spell.casting.dmgClass != magic || spell.casting.school >= 7)
            return false;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == AuraType.reflectSpellsSchool
                        && (aura.misc(k) & (1 << spell.casting.school)))
                {
                    const chance = aura.amount[k] + wardTalentChance(aura.spell);
                    if (chance > 0 && uniform01(map.random) * 100 < chance)
                        return true;
                }
        return false;
    }

    /// The reflect chance a mage's talent gives `ward` (Fire Ward: Improved Fire Ward; Frost Ward: Frost Warding).
    private int wardTalentChance(const(SpellInfo)* ward)
    {
        import dmangos.world.spellcast : effectValue;

        static immutable uint[] improvedFireWard = [11094, 13043], frostWarding = [11189, 28332];
        const(uint)[] ranks = ofFamily(ward, SpellFamily.mage, 0x8) ? improvedFireWard
            : ofFamily(ward, SpellFamily.mage, 0x100) ? frostWarding : null;
        int chance;
        foreach (id; ranks)
            if (player.knowsSpell(id))
                if (const talent = context.data.spells.spell(id))
                    foreach (i; 0 .. 3)
                        if (talent.effect[i] == SpellEffect.dummy)
                            chance = effectValue(*talent, i, player.data.level, 0);
        return chance;
    }

    /// A creature's `spell` came back off this player's ward: this player's now, at the creature (`caster`).
    package void reflectBack(const(SpellInfo)* spell, ulong caster)
    {
        castCustom(spell, SpellTargets(TargetFlags.unit, caster), CustomValues.init);
    }

    /// A creature's `spell` at this player was resisted whole: what procs on that (Magic Absorption).
    package void spellResistedBy(const(SpellInfo)* spell, UnitRef caster)
    {
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.procs : ProcEx, ProcHit;

        procAuras(ProcFlag.takeHarmfulSpell, caster, ProcHit(spell, ProcEx.resist, 0, 0, false));
    }

    // -----------------------------------------------------------------------
    // Priest
    // -----------------------------------------------------------------------

    /**
     * Spirit of Redemption (20711, a dummy aura): "Upon death, the priest becomes the Spirit of Redemption for 10
     * sec." A blow that would kill a priest with it leaves the priest at 1 health in the spirit's form (27827: 10 sec),
     * which cannot move or attack, nor be attacked, and heals free (27792, 27795); true if so. Its end is the death
     * (`classAuraChanged`).
     */
    package bool spiritOfRedemption()
    {
        enum uint talent = 20711, form = 27827, unattackable = 27792, pacified = 27795;
        if (player.auras.find(talent) is null || player.auras.find(form) !is null)
            return false;
        player.values.set!UNIT_FIELD_HEALTH(1u);
        foreach (spell; [form, unattackable, pacified])
            castCustom(spell, player.guid);
        flushPlayerChanges();
        return player.auras.find(form) !is null;
    }

    /// The Spirit of Redemption's form ended (`spiritOfRedemption`): the rest of it goes, and the priest dies.
    private void spiritOfRedemptionEnded(Aura aura)
    {
        enum uint form = 27827, unattackable = 27792, pacified = 27795;
        if (aura.spell.id != form || player is null || !player.alive)
            return;
        foreach (spell; [unattackable, pacified])
            if (auto other = player.auras.find(spell))
                removeAura(other);
        player.values.set!UNIT_FIELD_HEALTH(0u);
        flushPlayerChanges();
        playerDied(false);
    }

    // -----------------------------------------------------------------------
    // Warlock
    // -----------------------------------------------------------------------

    /**
     * `SPELL_EFFECT_SUMMON_POSSESSED` (Eye of Kilrogg: "Summons an Eye of Kilrogg and binds your vision to it"): the
     * creature of its misc value, in front of the caster, for the spell's time, possessed (`takeCharm`: the player
     * moves it and sees as it). The caster's aura of the spell (its dummy: "Controlling Eye of Kilrogg") lasts as
     * long; as either ends, the other does and the creature goes (`possessedSummonEnded`).
     */
    package void summonPossessedEffect(const(SpellInfo)* spell, size_t i)
    {
        import std.math : cos, sin;
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.spellcast : duration;

        const entry = cast(uint) spell.miscValue[i];
        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        if (!entry || ms <= 0)
            return;
        auto at = player.position;
        at.x += 2 * cos(at.orientation);
        at.y += 2 * sin(at.orientation);
        auto creature = context.summonCreature(map, entry, at, TempSpawnType.timedOrCorpse, ms, player.guid);
        if (creature is null)
            return;
        possessedSummon = creature.guid;
        takeCharm(creature, spell, true);
    }

    private ulong possessedSummon; // the creature of a `summonPossessedEffect`, while possessed

    /// The possession of a summoned creature ends (its spell's aura went, or it died): the creature goes.
    private void possessedSummonEnded(Aura aura)
    {
        if (!possessedSummon || !aura.spell.hasEffect(SpellEffect.summonPossessed))
            return;
        auto creature = cast(Creature) map.findObject(possessedSummon);
        possessedSummon = 0;
        if (creature !is null && charmed is creature)
            endCharm();
        if (creature !is null)
            map.removeObject(creature.guid);
    }

    /**
     * This player's aura (`aura`, on a creature now dead) procs on its death: Drain Soul's Soul Siphon (18371), its
     * chance its spell's (none) and Improved Drain Soul's (`SPELLMOD_CHANCE_OF_SUCCESS`: 50%, 100%).
     */
    package void deathAuraProc(Aura aura)
    {
        import dmangos.world.spellmods : SpellModOp;

        foreach (i; 0 .. 3)
            if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.procTriggerSpell && aura.spell.triggerSpell[i])
            {
                const chance = spellMod(SpellModOp.chanceOfSuccess, aura.spell, cast(float) aura.spell.casting.procChance);
                if (chance > 0 && uniform01(map.random) * 100 < chance)
                    castCustom(aura.spell.triggerSpell[i], player.guid);
            }
    }

    /**
     * Create Healthstone's script effect (its five sizes): the stone, or Improved Healthstone's (10%, 20%: "Increases
     * the amount of Health restored by your Healthstone") of the same size, whose own spell heals that much more.
     */
    private bool createHealthstone(const(SpellInfo)* spell)
    {
        // The create spell, its stone, and the stones of Improved Healthstone's two ranks (the items heal 100, 110,
        // 120; 250, 275, 300; 500, 550, 600; 800, 880, 960; 1200, 1320, 1440).
        static immutable uint[4][] stones = [[6201, 5512, 19004, 19005], [6202, 5511, 19006, 19007],
            [5699, 5509, 19008, 19009], [11729, 5510, 19010, 19011], [11730, 9421, 19012, 19013]];
        enum uint improvedRank1 = 18692, improvedRank2 = 18693;
        foreach (ref row; stones)
            if (row[0] == spell.id)
            {
                const rank = player.auras.find(improvedRank2) !is null ? 2 : player.auras.find(improvedRank1) !is null
                    ? 1 : 0;
                storeLoot(row[1 + rank], 1, 0, false);
                return true;
            }
        return false;
    }

    /**
     * Pyroclasm (override scripts 2188, 2189: "Gives your Rain of Fire, Hellfire, and Soul Fire spells a 13%" and "a
     * 26% chance to stun the target for 3 sec", 18093) at `target`: the spell's chance, shared by its ticks (Rain of
     * Fire's four, Hellfire's fifteen: their data's duration over their period), a Soul Fire's whole. Its data's proc
     * (a Dummy Trigger on damage over time) is this, not a cast of its own.
     */
    private void pyroclasm(const(SpellInfo)* spell, ulong target,
        imported!"dmangos.world.replication".Replica replica = null)
    {
        import dmangos.world.spellcast : castTime, duration;

        enum uint stun = 18093, hellfire = 1949;
        if (!ofFamily(spell, SpellFamily.warlock, 0x20 | 0x40) || target == player.guid)
            return;
        // Its ticks: of its own area (Rain of Fire), of Hellfire's channel (its Hellfire Effect is instant), none.
        int ticks = 1;
        const(SpellInfo)* periodic = ofFamily(spell, SpellFamily.warlock, 0x20) ? spell
            : castTime(*spell, context.client, player.data.level) == 0 ? context.data.spells.spell(hellfire) : null;
        if (periodic !is null)
            foreach (i; 0 .. 3)
                if (periodic.casting.amplitude[i] > 0)
                {
                    ticks = duration(*periodic, context.client, player.data.level) / periodic.casting.amplitude[i];
                    break;
                }
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.overrideClassScripts)
                {
                    const script = cast(int) aura.misc(i);
                    const chance = (script == 2188 ? 13.0f : script == 2189 ? 26.0f : 0) / (ticks > 0 ? ticks : 1);
                    if (chance > 0 && uniform01(map.random) * 100 < chance)
                        castAreaTickTrigger(stun, target, replica);
                }
    }

    /**
     * Improved Drain Mana (override scripts 2028, 2029: 15%, 30%): a share of the mana Drain Mana drained from
     * `victim` damages it.
     */
    package void classManaDrained(UnitRef victim, Aura aura, uint drained)
    {
        if (!ofFamily(aura.spell, SpellFamily.warlock, 0x10) || !victim || !victim.alive || !drained)
            return;
        int share;
        foreach (a; player.auras.list)
            foreach (i; 0 .. 3)
                if ((a.effects & (1 << i)) && a.type(i) == AuraType.overrideClassScripts)
                    share = a.misc(i) == 2028 ? 15 : a.misc(i) == 2029 ? 30 : share;
        if (!share)
            return;
        const damage = drained * share / 100;
        if (victim.kind == UnitKind.creature)
            spellDamage(aura.spell, victim.creature, damage, aura.spell.casting.school, false, -1, true); // (a tick's)
        else if (auto other = enemyPlayer(victim.combatGuid))
            spellDamageToPlayer(aura.spell, other, damage, false);
    }

    /**
     * Arcane Concentration's override scripts (1388 to 1392, one a rank, their mask Blizzard's): a Blizzard tick that
     * hits is "a damage spell [that] hits a target" though no spell hit sets off its proc (its ticks are a persistent
     * area's), so each such tick rolls the rank's chance (2% a rank: the talent's own proc chance) of Clearcasting.
     */
    private void arcaneConcentrationTick()
    {
        enum uint clearcasting = 12536;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.overrideClassScripts)
                {
                    const script = cast(int) aura.misc(i);
                    if (script >= 1388 && script <= 1392 && uniform01(map.random) * 100 < aura.spell.casting.procChance)
                    {
                        castCustom(clearcasting, player.guid);
                        return;
                    }
                }
    }

    /// The crit chance a class rule adds to `spell` against `target`: Shatter's against a frozen one.
    package float classCritBonus(const(SpellInfo)* spell, UnitRef target)
    {
        return target && frozenForSpellCrit(target) ? frozenTargetCritBonus(spell) : 0;
    }

    package float frozenTargetCritBonus(const(SpellInfo)* spell)
    {
        if (spell.casting.spellFamilyName != SpellFamily.mage)
            return 0;
        float bonus = 0;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.overrideClassScripts)
                    bonus += rankSpell(shatterCrit, cast(uint) aura.misc(i));
        return bonus;
    }

    /**
     * Frenzied Regeneration's tick (`Aura::TriggerSpell`): up to ten rage turned into health, by its rate; true if it
     * is this aura's (its own trigger spell, which the data leaves empty, is not cast).
     */
    package bool classPeriodicTrigger(Aura aura, size_t i)
    {
        import dmangos.world.defines : Power;

        enum uint frenziedHeal = 22845;
        if (!ofFamily(aura.spell, SpellFamily.druid) || aura.spell.casting.spellIconId != 50 || aura.type(i)
                != AuraType.periodicTriggerSpell)
            return false;
        const rage = cast(int) player.values.get!UNIT_FIELD_POWER1(Power.rage), taken = rage > 100 ? 100 : rage;
        player.modifyPower(Power.rage, -taken);
        castCustom(frenziedHeal, player.guid, CustomValues.first(taken * aura.amount[i] / 10));
        return true;
    }

    // -----------------------------------------------------------------------
    // Procs (`HandleProcTriggerSpellAuraProc`, `HandleDummyAuraProc`, `HandleOverrideClassScriptAuraProc`)
    // -----------------------------------------------------------------------

    package const(SpellInfo)* procAuraSpell; /// the aura whose proc is being cast (`m_triggeredByAuraSpell`)

    /**
     * A Proc Trigger Spell aura procced: what it casts by the class rules (`c` holds the spell's own: its trigger at
     * the other unit); false if it casts nothing. Deep Wounds bleeds a share of the weapon's average damage; Lightning
     * Shield's damage is its rank's; Illumination gives back the mana of the heal that crit; Blessed Recovery heals a
     * share of the blow; Ruthlessness and Seal Fate wait for the end of the finishing move.
     */
    package bool classProcTrigger(Aura aura, size_t i, const ref ProcHit hit, UnitRef other, ref ProcCast c)
    {
        // The warrior's, rogue's and hunter's (dmangos.world.physicalclasses): Improved Sap's stealth.
        bool casts;
        if (physicalClassProcTrigger(aura, c, casts))
            return casts;
        const spell = aura.spell;
        enum uint pyroclasmFirst = 18096;
        if (chainFirstRank(spell.id) == pyroclasmFirst)
            return false; // (`pyroclasm`)
        // Deep Wounds (its data names no family flags)
        if (spell.casting.spellFamilyName == SpellFamily.warrior && !spell.casting.spellFamilyFlags
                && spell.casting.spellIconId == 243)
        {
            const share = rankSpell(deepWoundsShare, spell.id);
            if (!share || !other)
                return false;
            enum uint deepWound = 12721;
            const offHand = hit.hand == AttackType.offHand;
            const average = (player.values.get!UNIT_FIELD_MINDAMAGE + player.values.get!UNIT_FIELD_MAXDAMAGE) / 2;
            const offAverage = (player.values.get!UNIT_FIELD_MINOFFHANDDAMAGE + player.values.get!UNIT_FIELD_MAXOFFHANDDAMAGE) / 2;
            // The share over its 12 seconds: each of its ticks (every 3 seconds) a part.
            import dmangos.world.spellcast : duration;

            const bleed = context.data.spells.spell(deepWound);
            const ticks = bleed is null || bleed.casting.amplitude[0] <= 0 ? 4
                : duration(*bleed, context.client, player.data.level) / bleed.casting.amplitude[0];
            c = ProcCast(deepWound, other.combatGuid,
                CustomValues.first(cast(int)((offHand ? offAverage : average) * share / 100 / ticks)));
            return true;
        }
        // Lightning Shield
        if (ofFamily(spell, SpellFamily.shaman, 0x400) && spell.casting.spellVisual == 37)
        {
            c.spell = rankSpell(lightningShieldDamage, spell.id);
            return c.spell != 0 && other;
        }
        // Illumination: the heal's mana back (of the spell cast: Holy Light's, Flash of Light's, Holy Shock's), by its
        // own spell (the data's trigger is 18350, a Dummy Trigger).
        if (ofFamily(spell, SpellFamily.paladin) && spell.casting.spellIconId == 241)
        {
            enum uint illuminationMana = 20272;
            const healed = hit.spell is null ? null : illuminatedSpell(hit.spell);
            if (healed is null)
                return false;
            c = ProcCast(illuminationMana, player.guid, CustomValues.first(cast(int) healed.casting.manaCost));
            return true;
        }
        // Blessed Recovery: a third of a share of the blow each tick.
        if (ofFamily(spell, SpellFamily.priest) && spell.casting.spellIconId == 1875)
        {
            const heal = rankSpell(blessedRecoveryHeal, spell.id);
            if (!heal)
                return false;
            c = ProcCast(heal, player.guid, CustomValues.first(cast(int)(hit.damage * aura.amount[i] / 100 / 3)));
            return true;
        }
        // Ruthlessness, Seal Fate: their point after the finishing move (else it would be spent with the others).
        enum uint ruthlessness = 14157, sealFate = 14189;
        if (c.spell == ruthlessness || c.spell == sealFate)
        {
            if (!other || other.combatGuid == player.guid)
                return false;
            if (castCombo)
            {
                heldProcs ~= c;
                return false; // (cast then, not now as well)
            }
        }
        return true;
    }

    /// The spell Illumination's mana is that of: the heal itself, or what cast it (Holy Light's, Flash of Light's own
    /// heal names its spell as its second amount; Holy Shock's heals are its ranks').
    private const(SpellInfo)* illuminatedSpell(const(SpellInfo)* heal)
    {
        foreach (ref row; holyShockHeal)
            if (row[1] == heal.id)
                return context.data.spells.spell(row[0]);
        if (effectCustom.has(1) && effectCustom.values[1] > 0)
            return context.data.spells.spell(cast(uint) effectCustom.values[1]);
        return heal;
    }

    /**
     * A dummy aura procced: Seal of Righteousness' holy damage on a swing, by the weapon's speed; Ignite's burn of a
     * share of a fire crit; Combustion's growing crit chance (gone at the last charge's crit); Master of Elements'
     * mana back. True if it did something.
     */
    package bool classDummyProc(Aura aura, size_t i, const ref ProcHit hit, UnitRef other, ref ProcCast[] casts)
    {
        const spell = aura.spell;
        // Sweeping Strikes: the blow again at another enemy near (Whirlwind's, and Execute's at one over a fifth of its
        // health, as a weapon strike); not its own strikes again.
        enum uint sweepingStrikes = 12292, sweepingStrikesCreature = 18765, sweepingDamage = 12723, sweepingWeapon = 26654;
        if (spell.id == sweepingStrikes || spell.id == sweepingStrikesCreature)
        {
            if (hit.damage == 0 || (hit.spell !is null && (hit.spell.id == sweepingDamage || hit.spell.id == sweepingWeapon)))
                return false;
            const second = anotherEnemyNear(other);
            if (!second)
                return false;
            enum uint whirlwind = 1680;
            const execute = hit.spell !is null && hit.spell.casting.targetAuraState == AuraState.healthless20Percent;
            auto unit = map.unit(second);
            if (hit.spell !is null && (hit.spell.id == whirlwind || execute && !(healthOf(unit)[0] * 5 < healthOf(unit)[1])))
                casts ~= ProcCast(sweepingWeapon, second);
            else
                casts ~= ProcCast(sweepingDamage, second, CustomValues.first(cast(int) hit.damage));
            return true;
        }
        // Retaliation: a strike back at each swing that does not come from behind.
        // (20240, `spell_retaliation_warrior`'s: 22858 is a creature's, `spell_retaliation_creature`)
        enum uint retaliation = 20230, retaliationStrike = 20240;
        if (spell.id == retaliation)
        {
            import dmangos.world.combat : hasInArc;

            if (!other || !hasInArc(player.position, other.position))
                return false;
            auto always = CustomValues.init;
            always.alwaysHits = true; // TRIGGERED_IGNORE_HIT_CALCULATION
            casts ~= ProcCast(retaliationStrike, other.combatGuid, always);
            return true;
        }
        if (paladinDummyProc(aura, i, hit, other, casts))
            return true;
        // Seal of Righteousness
        if (ofFamily(spell, SpellFamily.paladin, 0x8000000) && i == 0)
        {
            const damage = rankSpell(sealOfRighteousnessDamage, spell.id);
            if (!damage || !other)
                return false;
            casts ~= ProcCast(damage, other.combatGuid, CustomValues.first(sealOfRighteousnessAmount(aura.amount[i],
                spell)));
            return true;
        }
        // Ignite
        if (const share = rankSpell(igniteShare, spell.id))
        {
            enum uint igniteBurn = 12654;
            if (!other || !(hit.procEx & ProcEx.criticalHit))
                return false;
            casts ~= ProcCast(igniteBurn, other.combatGuid, CustomValues.first(cast(int)(hit.damage * share / 100)));
            return true;
        }
        // Combustion: each fire spell adds to the crit chance, a crit uses a charge; the last one ends it.
        enum uint combustion = 11129, combustionCrit = 28682;
        if (spell.id == combustion)
        {
            const crit = (hit.procEx & ProcEx.criticalHit) != 0;
            if (crit && aura.charges <= 1)
            {
                if (auto stacks = player.auras.find(combustionCrit))
                    removeAura(stacks);
                return true;
            }
            casts ~= ProcCast(combustionCrit, player.guid);
            return crit;
        }
        // Magic Absorption: a spell resisted whole gives back a share of the mana (29442), once a second at most
        // (its `spell_proc_event` row).
        enum uint magicAbsorption = 29441, magicAbsorptionMana = 29442;
        if (chainFirstRank(spell.id) == magicAbsorption && i == 0)
        {
            import dmangos.world.defines : Power;

            if (!(hit.procEx & ProcEx.resist))
                return false;
            const mana = cast(int)(player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana) * aura.amount[i] / 100);
            casts ~= ProcCast(magicAbsorptionMana, player.guid, CustomValues.first(mana));
            return true;
        }
        // Master of Elements
        if (ofFamily(spell, SpellFamily.mage) && spell.casting.spellIconId == 1920)
        {
            enum uint manaBack = 29077;
            if (hit.spell is null)
                return false;
            const cost = cast(int)(hit.spell.casting.manaCost + hit.spell.casting.manaCostPercentage
                * player.stats.baseMana / 100) * aura.amount[i] / 100;
            if (cost <= 0)
                return false;
            casts ~= ProcCast(manaBack, player.guid, CustomValues.first(cost));
            return true;
        }
        return false;
    }

    /**
     * A paladin's dummy aura procced: Eye for an Eye deals its share of a spell's crit back to the caster (25997), never
     * more than half the paladin's health (its tooltip).
     */
    private bool paladinDummyProc(Aura aura, size_t i, const ref ProcHit hit, UnitRef other, ref ProcCast[] casts)
    {
        static immutable uint[] eyeForAnEye = [9799, 25988];
        enum uint eyeForAnEyeDamage = 25997;
        if (!eyeForAnEye.canFind(aura.spell.id))
            return false;
        if (!other || !other.alive || !(hit.procEx & ProcEx.criticalHit) || !hit.damage)
            return false;
        const half = player.values.get!UNIT_FIELD_MAXHEALTH / 2;
        const back = cast(int) min(hit.damage * aura.amount[i] / 100, half);
        casts ~= ProcCast(eyeForAnEyeDamage, other.combatGuid, CustomValues.first(back));
        return back > 0;
    }

    /**
     * A haste aura procced (`HandleHasteAuraProc`): Blade Flurry strikes another enemy near for the swing's damage; true
     * if it did (a charge, as for the others, goes then).
     */
    package bool classHasteProc(Aura aura, size_t i, const ref ProcHit hit, UnitRef other, ref ProcCast[] casts)
    {
        enum uint bladeFlurry = 13877, bladeFlurryStrike = 22482;
        if (aura.spell.id != bladeFlurry)
            return aura.charges != 0;
        const second = anotherEnemyNear(other);
        if (!second)
            return false;
        casts ~= ProcCast(bladeFlurryStrike, second, CustomValues.first(cast(int) hit.damage));
        return true;
    }

    /// Another enemy in melee reach than `victim` (`SelectRandomUnfriendlyTarget`); 0 if none.
    private ulong anotherEnemyNear(UnitRef victim)
    {
        import dmangos.world.combat : canReachWithMelee;

        ulong[] near;
        foreach (creature; map.creaturesNear(player.position, 10))
            if (creature.guid != victim.combatGuid && spellEnemy(creature)
                    && canReachWithMelee(player.fighter, creature.fighter))
                near ~= creature.guid;
        if (near.length == 0)
            return 0;
        import std.random : uniform;

        return near[uniform(0, near.length, map.random)];
    }

    /**
     * Seal of Righteousness' damage on a swing of the main hand's weapon: its amount by the weapon's speed, in hundredths
     * (the 1.12 tooltip's own expression: "$/87;s to $/25;s Holy damage", from 1.15 to 4.0 seconds a swing), and what
     * Improved Seal of Righteousness adds. The spell power is the damage spell's own (Blizzard's coefficient of it,
     * `bonusCoefficient`).
     */
    private int sealOfRighteousnessAmount(int amount, const(SpellInfo)* seal)
    {
        import dmangos.world.defines : equipmentSlotMainhand;

        enum uint unarmed = 2000; // a fist's swing
        const item = player.inventory.equipped(equipmentSlotMainhand);
        const speed = (item is null || item.proto is null || !item.proto.details.delay ? unarmed
            : item.proto.details.delay) / 1000.0f;
        return cast(int)(amount * speed / 100 * (100 + improvedSealOfRighteousness()) / 100);
    }

    /**
     * Improved Seal of Righteousness' percent: its data names Judgement of Righteousness (family flag 0x400) for both, but
     * the seal's own swing damage (25713 and its ranks, of no family flags) is what its tooltip names first.
     */
    private int improvedSealOfRighteousness()
    {
        import dmangos.world.procs : affectMaskOf;

        enum ulong judgementOfRighteousness = 0x400;
        int percent;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == AuraType.addPctModifier
                        && aura.spell.casting.spellFamilyName == SpellFamily.paladin
                        && affectMaskOf(aura.spell, k) == judgementOfRighteousness)
                    percent += aura.amount[k];
        return percent;
    }

    /// An override class script aura procced: Nightfall's Shadow Trance on a Corruption or Drain Life tick.
    package bool classScriptProc(Aura aura, size_t i, const ref ProcHit hit, UnitRef other, ref ProcCast[] casts)
    {
        enum int nightfall = 4309;
        enum uint shadowTrance = 17941;
        if (!other || !other.alive)
            return false;
        if (aura.misc(i) == nightfall)
        {
            casts ~= ProcCast(shadowTrance, player.guid);
            return true;
        }
        return false;
    }

    /**
     * This player's spell, swing or tick hit `victim` (`hit`): what the victim's auras do to it (`victim`'s procs as
     * CMaNGOS runs them on its side, each on what its spell's proc flags take): Judgement of Light heals who strikes it
     * in melee, Judgement of Wisdom gives mana to who strikes it in melee, at range or with a spell, Vampiric Embrace
     * heals the priest's party by a share of the priest's shadow damage (its damage over time's too).
     */
    package void victimAuraProcs(UnitRef victim, uint flags, const ref ProcHit hit)
    {
        foreach (benefit; benefitsFromVictim(victim, player.guid, flags, hit))
            applySpellBenefit(benefit);
    }

    package static imported!"dmangos.cluster.protocol".RemoteSpellBenefit[] benefitsFromVictim(UnitRef victim,
        ulong caster, uint flags, const ref ProcHit hit)
    {
        import dmangos.cluster.protocol : RemoteSpellBenefit;

        auto set = victim.auraSet;
        if (set is null || !victim.alive)
            return null;
        const taken = flags << 1; // what the victim took: each taken flag is the dealt one's next bit
        RemoteSpellBenefit[] casts;
        enum uint vampiricEmbrace = 15286, vampiricHeal = 15290;
        foreach (aura; set.list)
        {
            if (!(aura.spell.casting.procFlags & taken))
                continue;
            if (aura.has(AuraType.procTriggerSpell))
            {
                auto heal = rankSpell(judgementOfLightHeal, aura.spell.id);
                if (!heal)
                    heal = rankSpell(judgementOfWisdomMana, aura.spell.id);
                if (heal && uniform01(victim.map.random) * 100 < aura.spell.casting.procChance)
                    casts ~= RemoteSpellBenefit(heal);
            }
            if (aura.spell.id == vampiricEmbrace && aura.caster == caster && hit.spell !is null
                    && hit.spell.casting.school == 5 && hit.damage)
                casts ~= RemoteSpellBenefit(vampiricHeal, cast(int)(hit.damage * aura.amount[0] / 100));
        }
        return casts;
    }

    package void applySpellBenefit(const ref imported!"dmangos.cluster.protocol".RemoteSpellBenefit benefit)
    {
        enum vampiricHeal = 15290;
        castCustom(benefit.spell, player.guid,
            benefit.spell == vampiricHeal ? CustomValues.first(benefit.amount) : CustomValues.init);
    }

    // -----------------------------------------------------------------------
    // Spell scripts' class calls (`SpellHost`, through `dmangos.world.sessionscripting`)
    // -----------------------------------------------------------------------

    import dmangos.script.api : ActionResult, EntityRef;

    /// This player cast `spell` at `target` (before its hits are rolled): the spell's script hears of it (`OnCast`).
    package void spellCastScript(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.script.api : SpellCast;

        spellScriptEvent(spell, SpellCast(EntityRef(player.guid), EntityRef(target)));
    }

    /// This player's `spell` reached `target`, or `missed` it: the spell's script hears of it (`OnHit`).
    package void spellLandedScript(const(SpellInfo)* spell, ulong target, bool missed)
    {
        import dmangos.script.api : SpellLanded;

        spellScriptEvent(spell, SpellLanded(EntityRef(player.guid), EntityRef(target), missed));
    }

    ActionResult hostCastCustom(EntityRef caster, uint spellId, EntityRef target, int[3] values, ubyte which)
    {
        if (caster.guid != player.guid)
        {
            // A creature's aura on this player whose tick its script runs here (Frost Blast): that creature casts.
            import dmangos.world.eventai : castTriggered;

            auto creature = caster.isCreature && map !is null ? map.creatureAt(caster.guid) : null;
            if (creature is null || creature.ai is null || !creature.alive)
                return ActionResult.notHere;
            creature.ai.bind(map);
            return creature.ai.castSpell(context.data.spells.spell(spellId), target.guid, castTriggered,
                CustomValues(values, which)) ? ActionResult.ok : ActionResult.notAllowed;
        }
        const result = castCustom(spellId, target.guid, CustomValues(values, which));
        return result == SpellCastResult.ok ? ActionResult.ok : result == SpellCastResult.unknown ? ActionResult.failed
            : ActionResult.notAllowed;
    }

    int classPower(EntityRef who, ubyte power)
    {
        import dmangos.world.defines : Power;

        if (who.guid != player.guid || power > Power.happiness)
            return 0;
        return cast(int) player.values.get!UNIT_FIELD_POWER1(cast(Power) power);
    }

    ActionResult hostSetPower(EntityRef who, ubyte power, int value)
    {
        import dmangos.world.defines : Power;

        if (who.guid != player.guid || power > Power.happiness)
            return ActionResult.notAllowed;
        player.modifyPower(cast(Power) power, value - classPower(who, power));
        flushPlayerChanges();
        return ActionResult.ok;
    }

    /// `CastHighestStealthRank` and the like: the highest rank this player knows of the chain of `firstRank`, cast at
    /// itself (its cooldown ended first, if asked).
    ActionResult hostCastHighestRank(EntityRef who, uint firstRank, bool resetCooldown)
    {
        if (who.guid != player.guid)
            return ActionResult.notAllowed;
        uint best;
        ubyte bestRank;
        foreach (id; player.spells)
        {
            const node = id in context.data.spells.chains;
            if ((id == firstRank || (node !is null && node.first == firstRank)) && (node is null ? 1 : node.rank) >= bestRank)
            {
                best = id;
                bestRank = node is null ? 1 : node.rank;
            }
        }
        if (!best)
            return ActionResult.failed;
        if (resetCooldown && !spellIsReady(best))
            clearCooldownFor(best);
        return castCustom(best, player.guid) == SpellCastResult.ok ? ActionResult.ok : ActionResult.notAllowed;
    }

    uint hostResetCooldowns(EntityRef who, uint family, uint schoolMask, uint except)
    {
        return who.guid == player.guid ? resetCooldowns(family, schoolMask, except) : 0;
    }

    /// The amounts of this player's auras of `auraType` that affect `spell` (`Aura::isAffectedOnSpell`).
    package int affectingAuraTotal(EntityRef who, const(SpellInfo)* spell, ubyte auraType)
    {
        import dmangos.world.spellmods : affects;

        if (who.guid != player.guid)
            return 0;
        int total;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == auraType && affects(aura, k, *spell))
                    total += aura.amount[k];
        return total;
    }
}
