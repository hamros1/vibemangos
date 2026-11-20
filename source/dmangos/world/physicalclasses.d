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
