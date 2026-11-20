/**
 * Spells whose effect is a script (`spell_scripts`): what their dummy or script effects do.
 */
module dmangos.scripts.spells;

import dmangos.script;

/**
 * Life Tap (`spell_life_tap`): the warlock turns health into mana. The health is the effect's amount with the spell
 * power's share, a cost (no damage taken); the mana as much, more by Improved Life Tap (a dummy aura on the spell),
 * given by its own spell (31818, `SMSG_SPELLENERGIZELOG`). A tap that would leave no health does nothing (the warlock
 * does not die of its own spell: CMaNGOS fizzles it).
 */
@spell("spell_life_tap")
struct LifeTap
{
    enum uint manaSpell = 31818;
    enum ubyte auraDummy = 4; // SPELL_AURA_DUMMY

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect != 0 || e.value <= 0)
            return;
        it.consume(); // done here; the spell has no database script to run besides
        const amount = cast(uint)(e.value + it.spellPower(e.caster));
        if (it.health(e.caster) <= amount)
            return;
        it.damage(e.caster, amount);
        const mana = cast(int)(amount * (it.affectingAuraTotal(e.caster, auraDummy) + 100) / 100);
        if (it.castCustom(e.caster, manaSpell, e.caster, [mana, 0, 0]) != ActionResult.ok)
            it.energize(e.caster, Power.mana, mana); // (a world without the server's spell)
    }
}

/**
 * Execute (`spell_warrior_execute`): as it is cast (whether it then lands or not), its damage spell (20647) strikes,
 * for its amount and all the rage left, each point worth the rank's multiplier.
 */
@spell("spell_warrior_execute")
struct WarriorExecute
{
    enum uint damageSpell = 20647;

    void on(ref SpellContext it, const ref SpellCast e)
    {
        const damage = it.effectValue(0) + cast(int)(it.power(e.caster, Power.rage) * it.damageMultiplier(0));
        it.castCustom(e.caster, damageSpell, e.target, [damage, 0, 0]);
    }
}

/// Execute's damage (`spell_warrior_execute_damage`): if it lands, all the rage is spent.
@spell("spell_warrior_execute_damage")
struct WarriorExecuteDamage
{
    void on(ref SpellContext it, const ref SpellLanded e)
    {
        if (!e.missed)
            it.setPower(e.caster, Power.rage, 0);
    }
}

/// Preparation (`spell_preparation`): every other rogue ability's cooldown ends.
@spell("spell_preparation")
struct Preparation
{
    enum uint family = 8; // SPELLFAMILY_ROGUE
    enum uint self = 14185;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect != 0)
            return;
        it.consume();
        it.resetCooldowns(e.caster, family, 0, self);
    }
}

/// Vanish (`spell_vanish`): as it is cast, the rogue stealths at once, by the highest Stealth it knows (its
/// cooldown ended for it).
@spell("spell_vanish")
struct Vanish
{
    enum uint stealth = 1784;

    void on(ref SpellContext it, const ref SpellCast e)
    {
        it.castHighestRank(e.caster, stealth);
    }
}

/// Improved Sap (`spell_improved_sap`): the Sap done, the rogue may stealth again at once.
@spell("spell_improved_sap")
struct ImprovedSap
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        it.castHighestRank(e.caster, Vanish.stealth);
    }
}

/// Hate to Zero (a creature's spell): the target's threat on the caster is gone; it fights on with
/// whoever has the most now.
@spell("spell_hate_to_zero")
struct HateToZero
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.target)
            it.modifyThreat(e.caster, e.target, -100);
        it.consume();
    }
}

/**
 * Curse of Agony: its damage grows: of its twelve ticks, the first four deal half the average and
 * the last four half again as much, rounded up (the total stays what the spell says: 84 of rank 1's 7 a tick).
 */
@spell("spell_curse_of_agony")
struct CurseOfAgony
{
    void on(ref SpellContext it, const ref AuraTicked e)
    {
        if (e.ticks < 3)
            return;
        const third = e.ticks / 3;
        if (e.tick <= third)
            it.setAmount(e.amount / 2);
        else if (e.tick > e.ticks - third)
            it.setAmount(e.amount + (e.amount + 1) / 2); // (the half a point the first ticks lost)
    }
}
