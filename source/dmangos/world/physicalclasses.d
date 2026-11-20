/**
 * The warrior's, rogue's and hunter's rules that the data alone does not give, each from its 1.12.1 tooltip
 * (docs/spells/warrior.md, rogue.md, hunter.md; the hidden numbers in docs/FORMULAS.md). Mixed into
 * `dmangos.world.character.Character` beside `dmangos.world.classspells.ClassSpells`, which calls in here for these
 * classes' dummy effects, procs and stance changes. Tested on the real data in
 * `dmangos.world.realclass_warrior_rogue_hunter`.
 */
module dmangos.world.physicalclasses;

/// Unbridled Wrath's and Mace Specialization's ranks (warrior and rogue): their tooltips give a flat chance on a
/// hit ("a 40% chance", "a 6% chance"), which their spells' `ProcChance` has; not a rate a minute.
static immutable uint[] flatChanceProcs = [12322, 12999, 13000, 13001, 13002, 12284, 12701, 12702, 12703, 12704,
    13709, 13800, 13801, 13802, 13803];

/// The proc flag of a hunter's trap going off (`PROC_FLAG` 0x200000: Entrapment's only one at rank 1).
enum uint procOnTrapActivation = 0x200000;

/// Entrapment's ranks: they proc on a trap going off only ("Gives your Immolation Trap, Frost Trap, and Explosive
/// Trap a 25% chance to entrap the target"), whatever else their higher ranks' flags name.
static immutable uint[] trapActivationProcs = [19184, 19387, 19388, 19389, 19390];

/// See the module documentation.
mixin template PhysicalClassRules()
{
    import dmangos.world.auras : Aura, AuraType;
    import dmangos.world.classspells : CustomValues, SpellFamily;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : PlayerClass, Power;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.unit : UnitRef;
    import dmangos.world.updatefields;

    /**
     * A warrior's, rogue's or hunter's dummy effect: Last Stand ("temporarily grants you 30% of your maximum hit
     * points": 12976 by that amount). True if it is one.
     */
    package bool physicalClassDummy(const(SpellInfo)* spell, size_t i, UnitRef target, int value)
    {
        enum uint lastStand = 12975, lastStandHealth = 12976;
        if (spell.id == lastStand)
        {
            const health = cast(int)(player.values.get!UNIT_FIELD_MAXHEALTH * 30 / 100);
            castCustom(lastStandHealth, player.guid, CustomValues.first(health));
            return true;
        }
        return false;
    }

    /**
     * A Proc Trigger Spell aura of these classes procced (`c`: its trigger at the other unit): true if it is one of
     * theirs, `casts` then whether `c` is still cast. Improved Sap's "return to stealth mode": the highest Stealth
     * known, its cooldown over (its trigger, 14093, is no stealth).
     */
    package bool physicalClassProcTrigger(Aura aura, ref ProcCast c, out bool casts)
    {
        import dmangos.script.api : EntityRef;

        enum uint improvedSapStealth = 14093, stealthFirstRank = 1784;
        if (c.spell == improvedSapStealth)
        {
            hostCastHighestRank(EntityRef(player.guid), stealthFirstRank, true);
            return true;
        }
        return false;
    }

    /**
     * The amounts of an aura of these classes' about to go on: Pathfinding's "increases the speed bonus of your
     * Aspect of the Cheetah and Aspect of the Pack by 6%" on their speed, the first effect (the talent's data names
     * the second, their daze's trigger).
     */
    package void physicalClassAuraValues(const(SpellInfo)* spell, ref int[3] values)
    {
        import dmangos.world.classspells : ofFamily;
        import dmangos.world.spellmods : SpellModOp;

        enum ulong cheetahAndPack = 0x200000;
        if (ofFamily(spell, SpellFamily.hunter, cheetahAndPack)
                && spell.casting.applyAuraName[0] == AuraType.modIncreaseSpeed)
            values[0] += spellMod(SpellModOp.effect2, spell, 0);
    }

    /**
     * A hunter's trap effect (`spell`, cast by its trap) reached `landed`: Immolation, Explosive and Frost Trap's
     * effects set off what procs on a trap going off (Entrapment), at each target.
     */
    package void trapEffectLanded(const(SpellInfo)* spell, const(ulong)[] landed)
    {
        import dmangos.world.classspells : ofFamily;
        import dmangos.world.procs : ProcEx, ProcHit;

        enum ulong entrapping = 0x4 | 0x10; // Immolation and Explosive Trap's effects, Frost Trap's
        if (!ofFamily(spell, SpellFamily.hunter, entrapping) || player.data.classId != PlayerClass.hunter)
            return;
        foreach (target; landed)
            if (target != player.guid)
                if (auto unit = map.unit(target))
                    procAuras(procOnTrapActivation, unit, ProcHit(spell, ProcEx.normalHit, 0, 0, true));
    }

    /**
     * A tick of this hunter's heal over time on `target` (Mend Pet): Improved Mend Pet ("Gives the Mend Pet spell a
     * 50% chance of cleansing $24406s1 Curse, Disease, Magic or Poison effect from the pet each tick": its override
     * scripts 4086 and 4087, their amount the chance, on the spells of their mask) casts 24406, its tooltip's, at it.
     */
    package void hunterHealTick(Aura heal, UnitRef target)
    {
        import std.random : uniform01;
        import dmangos.world.spellmods : affects;

        enum uint cleansing = 24406;
        if (!target || !target.alive || player.data.classId != PlayerClass.hunter)
            return;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == AuraType.overrideClassScripts
                        && (aura.misc(k) == 4086 || aura.misc(k) == 4087) && affects(aura, k, *heal.spell))
                {
                    if (uniform01(map.random) * 100 < aura.amount[k])
                        castCustom(cleansing, target.combatGuid);
                    return;
                }
    }

    /**
     * This hunter's Scorpid Sting went on `target`: Improved Scorpid Sting ("Reduces the Stamina of targets affected
     * by your Scorpid Sting by 10% of the amount of Strength reduced", 20%, 30%: its override scripts 2388, 2389,
     * 2390, whose data has no percentage) casts 19486, the stamina's ("Stamina reduced by $s1"), at it.
     */
    package void scorpidStingLanded(Aura sting, UnitRef target)
    {
        import dmangos.world.classspells : ofFamily;

        enum uint staminaReduced = 19486;
        enum ulong scorpidSting = 0x8000;
        if (!target || !ofFamily(sting.spell, SpellFamily.hunter, scorpidSting) || sting.caster != player.guid)
            return;
        int percent;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == AuraType.overrideClassScripts
                        && aura.misc(k) >= 2388 && aura.misc(k) <= 2390)
                    percent = (aura.misc(k) - 2387) * 10;
        if (!percent)
            return;
        int strength;
        foreach (k; 0 .. 3)
            if ((sting.effects & (1 << k)) && sting.type(k) == AuraType.modStat && sting.misc(k) == 0)
                strength = sting.amount[k];
        if (strength < 0)
            castCustom(staminaReduced, target.combatGuid, CustomValues.first(strength * percent / 100));
    }

    /// This hunter's Scorpid Sting left `target`: the stamina Improved Scorpid Sting took goes with it ("targets
    /// affected by your Scorpid Sting").
    package void scorpidStingLost(Creature target, Aura sting)
    {
        import dmangos.world.classspells : ofFamily;

        enum uint staminaReduced = 19486;
        if (!ofFamily(sting.spell, SpellFamily.hunter, 0x8000) || sting.caster != player.guid)
            return;
        foreach (aura; target.auras.list.dup)
            if (aura.spell.id == staminaReduced && aura.caster == player.guid)
                target.loseAura(aura, map);
    }

    /**
     * A warrior took a stance (`apply`): the rage goes but what Tactical Mastery keeps ("You retain up to 25 of your
     * rage points when you change stances": its override script numbers 831 to 835 are its ranks, 5 points each).
     */
    package void warriorStanceTaken()
    {
        if (player.data.classId != PlayerClass.warrior)
            return;
        int kept;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == AuraType.overrideClassScripts
                        && aura.misc(k) >= 831 && aura.misc(k) <= 835)
                    kept = (aura.misc(k) - 830) * 50; // rage in tenths
        const rage = cast(int) player.values.get!UNIT_FIELD_POWER1(Power.rage);
        if (rage > kept)
            player.modifyPower(Power.rage, kept - rage);
    }
}
