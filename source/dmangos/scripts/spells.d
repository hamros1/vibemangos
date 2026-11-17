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
