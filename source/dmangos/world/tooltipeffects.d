/**
 * What a spell's 1.12.1 tooltip promises beyond its data: effects Blizzard's server added that the client's data has
 * no slot or row for. Each row is an aura's hidden effect, counted by the aura totals (`AuraSet.multiplier`,
 * `AuraSet.attackTimeFactor`) as if the data had it; it quotes the tooltip it comes from. None comes from an emulator.
 */
module dmangos.world.tooltipeffects;

import dmangos.world.auras : AuraType;

/// An aura's effect only its tooltip gives.
struct HiddenEffect
{
    uint spell;
    AuraType type;
    int misc; /// a school mask for damage taken
    int amount;
    string tooltip;
}

/// See the module documentation.
static immutable HiddenEffect[] hiddenEffects = [
    // Barkskin (22812): its data has the pushback immunity and the longer casts only.
    HiddenEffect(22812, AuraType.modDamagePercentTaken, 1, -20, "Physical damage taken is reduced by 20%."),
    HiddenEffect(22812, AuraType.modMeleeHaste, 0, -25, "melee combat is slowed by 25%."),
];

/// The hidden effects of `spell` (none for most: a scan of a short table).
const(HiddenEffect)[] hiddenEffectsOf(uint spell) pure nothrow @nogc @safe
{
    foreach (i, ref e; hiddenEffects)
        if (e.spell == spell)
        {
            size_t end = i;
            while (end < hiddenEffects.length && hiddenEffects[end].spell == spell)
                ++end;
            return hiddenEffects[i .. end];
        }
    return null;
}
