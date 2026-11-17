/**
 * Experience for kills (CMaNGOS `Tools/Formulas.h`, `MaNGOS::XP`): what a creature is worth to a
 * player of a level, and how a group shares it.
 */
module dmangos.world.experience;

/// `XP::IsTrivialLevelDifference`: a creature this far below gives nothing (grey).
bool isTrivialLevelDifference(uint unitLevel, uint targetLevel) pure nothrow @nogc @safe
{
    if (unitLevel <= targetLevel)
        return false;
    const diff = unitLevel - targetLevel;
    static immutable uint[12] limit = [4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11];
    const band = unitLevel / 5;
    return diff > (band < limit.length ? limit[band] : 12);
}

/// `XP::GetGrayLevel`
uint grayLevel(uint level) pure nothrow @nogc @safe
{
    if (level <= 5)
        return 0;
    if (level <= 39)
        return level - 5 - level / 10;
    if (level <= 59)
        return level - 1 - level / 5;
    return level - 9;
}

/// `XP::GetZeroDifference`
uint zeroDifference(uint level) pure nothrow @nogc @safe
{
    if (level < 8)
        return 5;
    if (level < 10)
        return 6;
    if (level < 12)
        return 7;
    if (level < 16)
        return 8;
    if (level < 20)
        return 9;
    if (level < 30)
        return 11;
    if (level < 40)
        return 12;
    if (level < 45)
        return 13;
    if (level < 50)
        return 14;
    if (level < 55)
        return 15;
    if (level < 60)
        return 16;
    return 17;
}

/// `XP::BaseGain`: a creature of `mobLevel` to a player of `level`, before its rank and multiplier.
float baseGain(uint level, uint mobLevel) pure nothrow @nogc @safe
{
    const base = level * 5 + 45;
    if (mobLevel >= level)
    {
        const diff = mobLevel - level > 4 ? 4 : mobLevel - level;
        return base * (1.0f + 0.05f * diff);
    }
    if (isTrivialLevelDifference(level, mobLevel))
        return 0;
    return base * (1.0f - float(level - mobLevel) / zeroDifference(level));
}

/// What `XP::Gain` needs of the creature.
struct KillValue
{
    uint level;
    bool elite;          /// rank neither normal nor rare
    bool raidMap;        /// `IsNoRaid` false: elites give double, not two and a half
    float multiplier = 1; /// `ExperienceMultiplier`
    bool noXp;           /// a critter, `NO_XP`, a pet or a totem
}

/// `XP::Gain` (kill rate 1, no damage by others).
uint killGain(uint level, const KillValue creature) pure nothrow @nogc @safe
{
    import std.math : nearbyint;

    if (creature.noXp)
        return 0;
    float gain = baseGain(level, creature.level);
    if (gain == 0)
        return 0;
    if (creature.elite)
        gain *= creature.raidMap ? 2.0f : 2.5f;
    gain *= creature.multiplier;
    return cast(uint) nearbyint(gain);
}

/// `XP::xp_in_group_rate`: the group's bonus for its size.
float groupRate(uint count) pure nothrow @nogc @safe
{
    switch (count)
    {
    case 0:
    case 1:
    case 2:
        return 1.0f;
    case 3:
        return 1.166f;
    case 4:
        return 1.3f;
    case 5:
        return 1.4f;
    default:
        const rate = 1.0f - count * 0.05f;
        return rate > 0.01f ? rate : 0.01f;
    }
}

/// `CONFIG_FLOAT_GROUP_XP_DISTANCE`: group members farther than this from a kill share none of it.
enum float groupXpDistance = 74;

unittest
{
    // Same level: 45 + 5 * level.
    assert(killGain(1, KillValue(1)) == 50 && killGain(10, KillValue(10)) == 95);
    // Higher: 5% a level, at most four.
    assert(killGain(10, KillValue(12)) == 104 && killGain(10, KillValue(20)) == 114); // 104.5: to even
    // Lower: down to nothing at the grey level.
    assert(killGain(10, KillValue(8)) == 68 && killGain(10, KillValue(4)) == 0); // 95 * (1 - 2/7)
    assert(grayLevel(10) == 4 && grayLevel(50) == 39 && grayLevel(60) == 51);
    // Elites in the world, and a multiplier.
    assert(killGain(10, KillValue(10, true)) == 238 && killGain(10, KillValue(10, true, true)) == 190);
    assert(killGain(10, KillValue(10, false, false, 0.5f)) == 48);
    assert(killGain(10, KillValue(10, false, false, 1, true)) == 0);
    assert(groupRate(2) == 1 && groupRate(3) == 1.166f && groupRate(5) == 1.4f);
}
