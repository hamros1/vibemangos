/**
 * Procs of a creature's auras: what a player's proc engine (`dmangos.world.procs`) does for its auras, for a
 * creature's, mixed into `dmangos.world.creatureai.CreatureAI`. A creature's swing or spell that hit (or
 * missed) is a set of `ProcFlag`s and a `ProcHit`; each of its Proc Trigger Spell auras that the flags (its
 * `spell_proc_event` row's, else its spell's) and the
 * hit kinds allow rolls its chance, changed by its owner's talents (`SPELLMOD_CHANCE_OF_SUCCESS`: Frenzy on the
 * hunter pet's "Chance to proc frenzy"), and casts its spell at the unit it struck (or at itself, as that spell's
 * targets say: Frenzy Effect). A proc uses a charge (Intimidation's one), and an aura out of them goes. What a proc
 * casts sets off no procs.
 *
 * Every creature's auras proc so: a pet's, and the world's creatures' (a mob's Thrash, whose extra swings a creature's
 * cast does now: `dmangos.world.spelleffects`). A player's proc engine (`dmangos.world.procs`) keeps its class rules,
 * cooldowns and weapon checks of its own: one engine for both is still to come (docs/SPELLS.md, step 6).
 */
module dmangos.world.creatureprocs;

/// See the module documentation.
mixin template CreatureProcs()
{
    import dmangos.world.procs : effectProcsOn, procEventMatches, ProcHit;

    private bool inCreatureProc; // casting what its procs cast

    /// `flags` happened with `other` (the unit it struck), as `hit` says: its auras that proc on it do.
    package void procAuras(uint flags, UnitRef other, const ProcHit hit)
    {
        import std.algorithm.searching : canFind;
        import std.random : uniform01;
        import dmangos.world.auras : Aura;
        import dmangos.world.context : WorldContext;
        import dmangos.world.spellmods : SpellModOp;

        if (inCreatureProc || !me.alive || world_ is null || me.auras.list.length == 0)
            return;
        auto context = cast(WorldContext) lore;
        if (context is null)
            return;
        inCreatureProc = true;
        scope (exit)
            inCreatureProc = false;
        auto owner = petModOwner();
        static struct ProcCast
        {
            const(SpellInfo)* spell;
            ulong target;
        }

        ProcCast[] casts;
        Aura[] spent;
        foreach (aura; me.auras.list)
        {
            if (!aura.has(AuraType.procTriggerSpell))
                continue;
            const event = context.data.spells.procEvent(aura.spell.id);
            const auraFlags = event !is null && event.procFlags ? event.procFlags : aura.spell.casting.procFlags;
            if (!procEventMatches(auraFlags, event, flags, hit))
                continue;
            if (hit.spell !is null && hit.spell.id == aura.spell.id)
                continue;
            ubyte effects;
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.procTriggerSpell
                        && effectProcsOn(aura.spell, i, event, hit))
                    effects |= 1 << i;
            if (!effects)
                continue;
            float chance = event !is null && event.customChance ? event.customChance : aura.spell.casting.procChance;
            if (owner !is null)
                chance = owner.petSpellMod(SpellModOp.chanceOfSuccess, aura.spell, chance, me);
            // (no roll for none or a certainty: a hunter pet without Frenzy rolls nothing at its crits)
            if (chance <= 0 || (chance < 100 && uniform01(world_.random) * 100 >= chance))
                continue;
            foreach (i; 0 .. 3)
                if (effects & (1 << i))
                    if (const trigger = lore.spellInfo(aura.spell.triggerSpell[i]))
                        casts ~= ProcCast(trigger, other ? other.combatGuid : me.guid);
            if (aura.charges && --aura.charges == 0)
                spent ~= aura;
        }
        foreach (aura; spent)
            if (me.auras.list.canFind!(a => a is aura))
                me.loseAura(aura, world_);
        foreach (c; casts)
            if (me.alive)
                castSpell(c.spell, c.target, castTriggered);
        if (spent.length || casts.length)
            world_.flushCreature(me);
    }
}
