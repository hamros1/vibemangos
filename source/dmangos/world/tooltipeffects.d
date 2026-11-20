/**
 * What a spell's 1.12.1 tooltip promises beyond its data: effects Blizzard's server added that the client's data has
 * no slot or row for. Each row is an aura's hidden effect, counted by the aura totals (`AuraSet.multiplier`,
 * `AuraSet.attackTimeFactor`) as if the data had it; it quotes the tooltip it comes from. Beside them: what a
 * sacrifice of a pet gives by the pet (`sacrificeEffects`). None comes from an emulator.
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

/// What a spell that takes its caster's pet gives its caster, by the pet: the tooltip names each demon's effect;
/// its data only kills the demon (`SPELL_EFFECT_INSTAKILL` at the pet).
struct SacrificeEffect
{
    uint spell;
    uint petEntry;
    uint aura;   /// the spell the caster casts on itself (its aura's own tooltip says the same)
    string tooltip;
}

/// See `SacrificeEffect`: Demonic Sacrifice (18788). "The effect is canceled if any Demon is summoned."
static immutable SacrificeEffect[] sacrificeEffects = [
    SacrificeEffect(18788, 416, 18789, "Imp: Increases your Fire damage by 15%."),
    SacrificeEffect(18788, 1860, 18790, "Voidwalker: Restores 3% of total Health every 4 sec."),
    SacrificeEffect(18788, 1863, 18791, "Succubus: Increases your Shadow damage by 15%."),
    SacrificeEffect(18788, 417, 18792, "Felhunter: Restores 2% of total Mana every 4 sec."),
];

/// The aura `spell` gives its caster for sacrificing a pet of `petEntry`; 0 if none.
uint sacrificeAuraOf(uint spell, uint petEntry) pure nothrow @nogc @safe
{
    foreach (ref e; sacrificeEffects)
        if (e.spell == spell && e.petEntry == petEntry)
            return e.aura;
    return 0;
}

/// Whether `aura` is one a sacrifice gives (which a demon summoned cancels).
bool isSacrificeAura(uint aura) pure nothrow @nogc @safe
{
    foreach (ref e; sacrificeEffects)
        if (e.aura == aura)
            return true;
    return false;
}
