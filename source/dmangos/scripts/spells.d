/**
 * Spells whose effect is a script (`spell_scripts`): what their dummy or script effects do.
 */
module dmangos.scripts.spells;

import dmangos.script;

/**
 * Life Tap: the warlock turns health into as much mana. A tap that would leave no health does
 * nothing (the warlock does not die of its own spell).
 */
@spell("spell_life_tap")
struct LifeTap
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect != 0 || e.value <= 0)
            return;
        it.consume(); // done here; the spell has no database script to run besides
        const amount = cast(uint) e.value;
        if (it.health(e.caster) <= amount)
            return;
        it.damage(e.caster, amount);
        it.energize(e.caster, Power.mana, amount);
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
 * the last four half again as much (the total stays what the spell says).
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
            it.setAmount(e.amount + e.amount / 2);
    }
}
