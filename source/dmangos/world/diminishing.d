/**
 * Diminishing returns on crowd control in PvP, as Blizzard's 1.x patch notes give them (docs/FORMULAS.md,
 * "Diminishing returns"). Patch 1.4.0: "When a spell with diminishing returns is used against a target in PvP, the
 * first effect has full duration. On the second use of the same category of spell (e.g. slowing), that spell's
 * duration is reduced by 50%. On the third use, the duration is reduced by 75%. On the fourth attempt, the target
 * becomes immune to the spell. Spells must be used on the same target within 15 seconds of the *end* of the
 * duration in order to be diminished."
 *
 * The categories are the notes': slowing (Frost Shock) and immobilizing (Entangling Roots, Frost Nova) from 1.4.0;
 * fear (and Seduction, "considered a Fear effect", 1.4.0; Death Coil's horror "not diminished", 1.8.0); charm
 * (Gnomish Mind Control Cap "in the Charm category", 1.8.0); controlled stuns (Cheap Shot, Hammer of Justice,
 * Charge; grenades, 1.11.0), which the stuns of talents and seals that procs cast "no longer diminish or [are]
 * diminished by" (1.9.0); Freezing Trap (1.10.0). Blizzard’s Classic Era clarifications also group Scatter Shot and Wyvern Sting with Freezing Trap.
 */
module dmangos.world.diminishing;

import core.time : MonoTime, msecs, seconds;

import dmangos.world.spells : SpellInfo;

/// A diminishing returns category: auras of one diminish each other.
enum DrCategory : ubyte
{
    none,
    controlledStun, /// a stun cast on purpose (Cheap Shot, Hammer of Justice, Charge's, Kidney Shot, a grenade)
    fear,           /// Fear, Howl of Terror, Psychic Scream, Intimidating Shout; Seduction
    charm,          /// Mind Control, the Gnomish Mind Control Cap
    immobilize,     /// Entangling Roots, Frost Nova
    slow,           /// Frost Shock
    freezingTrap,   /// Freezing Trap's effect
}

/// Spell mechanics (`Mechanics`) the categories go by.
private enum : uint
{
    mechanicCharm = 1,
    mechanicFear = 5,
    mechanicStun = 12,
    mechanicFreeze = 13,
}

/// Spell families and flags of the slowing and immobilizing spells the 1.4.0 notes name (every rank has them).
private enum : uint
{
    familyMage = 3,
    familyDruid = 7,
    familyShaman = 11,
}
private enum ulong flagFrostNova = 0x40, flagEntanglingRoots = 0x200, flagFrostShock = 0x80000000;

/// Seduction: a charm by its mechanic, a fear by the 1.4.0 notes.
private enum uint seduction = 6358;

/**
 * The stuns of talents and seals that procs cast, which 1.9.0 took out of the controlled stuns: Mace
 * Specialization's (5530), Improved Starfire's (16922), Impact (12355), Seal of Justice's (20170), Blackout (15269),
 * Pyroclasm (18093), Improved Revenge's (12798), Improved Concussive Shot (19410).
 */
private static immutable uint[] procStuns = [5530, 16922, 12355, 20170, 15269, 18093, 12798, 19410];

/// The category of a hostile aura of `spell` (its mechanic, as the spell data has it, or its family flags).
DrCategory drCategory(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    import std.algorithm.searching : canFind;

    if (spell.id == seduction)
        return DrCategory.fear;
    const family = spell.casting.spellFamilyName, flags = spell.casting.spellFamilyFlags;
    if ((family == familyMage && (flags & flagFrostNova)) || (family == familyDruid && (flags & flagEntanglingRoots)))
        return DrCategory.immobilize;
    if (family == familyShaman && (flags & flagFrostShock))
        return DrCategory.slow;
    bool has(uint mechanic)
    {
        return spell.casting.mechanic == mechanic || spell.casting.effectMechanic[0] == mechanic
            || spell.casting.effectMechanic[1] == mechanic || spell.casting.effectMechanic[2] == mechanic;
    }
    // Scatter Shot and the sleep ranks of Wyvern Sting share Freezing Trap's PvP timer.
    static immutable uint[] hunterDisorients = [19503, 19386, 24132, 24133];
    if (has(mechanicFreeze) || hunterDisorients.canFind(spell.id))
        return DrCategory.freezingTrap;
    if (has(mechanicStun))
        return procStuns.canFind(spell.id) ? DrCategory.none : DrCategory.controlledStun;
    if (has(mechanicFear))
        return DrCategory.fear;
    if (has(mechanicCharm))
        return DrCategory.charm;
    return DrCategory.none;
}

/// How long after the end of the last diminished aura of a category its returns start whole again.
enum resetAfter = 15.seconds;

/// One unit's diminishing returns, by category.
struct DiminishingReturns
{
    private static struct Entry
    {
        ubyte level;      /// auras of the category already landed: 0 full, 1 half, 2 a quarter, 3 immune
        MonoTime resetAt; /// when the level goes back to 0: 15 seconds after the last one's end
    }

    private Entry[DrCategory.max + 1] entries;

    /**
     * An aura of `category` lasting `durationMs` lands `now`: how long it lasts (full, half, a quarter), 0 if the
     * unit is immune to it; `level` says which (0 to 3). Nothing changes for an aura of no category or of no
     * duration.
     */
    int apply(DrCategory category, int durationMs, MonoTime now, out uint level) pure nothrow @nogc @safe
    {
        if (category == DrCategory.none || durationMs <= 0)
            return durationMs;
        auto entry = &entries[category];
        if (now >= entry.resetAt)
            entry.level = 0;
        level = entry.level;
        if (entry.level >= 3)
            return 0; // immune; it does not lengthen the wait
        const lasts = durationMs >> entry.level; // 100%, 50%, 25%
        ++entry.level;
        entry.resetAt = now + lasts.msecs + resetAfter;
        return lasts;
    }

    /// An aura of `category` ended `now`, maybe before its time (broken by damage, dispelled): the 15 seconds count
    /// from now.
    void ended(DrCategory category, MonoTime now) pure nothrow @nogc @safe
    {
        if (category == DrCategory.none)
            return;
        auto entry = &entries[category];
        if (entry.level && entry.resetAt > now + resetAfter)
            entry.resetAt = now + resetAfter;
    }
}

/// The 1.4.0 rule: full, half, a quarter, immune; whole again 15 seconds after the last one ends.
pure nothrow @nogc @safe unittest
{
    DiminishingReturns dr;
    const start = MonoTime.zero + 1000.seconds;
    uint level;
    assert(dr.apply(DrCategory.fear, 8000, start, level) == 8000 && level == 0);
    assert(dr.apply(DrCategory.fear, 8000, start + 9.seconds, level) == 4000 && level == 1);
    assert(dr.apply(DrCategory.fear, 8000, start + 14.seconds, level) == 2000 && level == 2);
    assert(dr.apply(DrCategory.fear, 8000, start + 17.seconds, level) == 0 && level == 3, "the fourth: immune");
    assert(dr.apply(DrCategory.controlledStun, 4000, start + 17.seconds, level) == 4000, "another category");
    // The third ended at 14 + 2 = 16 s: whole again at 31 s, not before.
    assert(dr.apply(DrCategory.fear, 8000, start + 30.seconds, level) == 0);
    assert(dr.apply(DrCategory.fear, 8000, start + 31.seconds, level) == 8000 && level == 0);
    // Broken early: the 15 seconds count from the break.
    assert(dr.apply(DrCategory.fear, 8000, start + 40.seconds, level) == 4000);
    dr.ended(DrCategory.fear, start + 41.seconds);
    assert(dr.apply(DrCategory.fear, 8000, start + 56.seconds, level) == 8000, "15 s after it broke");
    assert(dr.apply(DrCategory.none, 8000, start, level) == 8000);
}
