/**
 * Experience for kills: what a creature is worth to a player of a level, how a group shares it, and rest. The rules
 * and their sources (Wowpedia's 1.x research, Blizzard's Exhaustion.dbc) are in docs/FORMULAS.md, "Experience".
 */
module dmangos.world.experience;

/**
 * The highest level that is grey (worth nothing) to a player of `level`: Wowpedia "Mob experience"'s table,
 * with level 60's 47 as 1.12 had it (the page: "changed from the previously known 47 to 51" in the Burning
 * Crusade). Kills, honor and reputation share it.
 */
uint grayLevel(uint level) pure nothrow @nogc @safe
{
    if (level <= 5)
        return 0;
    if (level <= 39)
        return level - 5 - level / 10;
    return level - 1 - level / 5;
}

/// Whether `targetLevel` is grey to a player of `level`.
bool isGray(uint level, uint targetLevel) pure nothrow @nogc @safe
{
    return targetLevel <= grayLevel(level);
}

/// The level difference below the player at which a kill's experience falls to nothing.
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

/// What a creature of `mobLevel` is worth to a player of `level`, before its rank and multiplier.
float baseGain(uint level, uint mobLevel) pure nothrow @nogc @safe
{
    const base = level * 5 + 45;
    if (mobLevel >= level)
    {
        const diff = mobLevel - level > 4 ? 4 : mobLevel - level;
        return base * (1.0f + 0.05f * diff);
    }
    if (isGray(level, mobLevel))
        return 0;
    return base * (1.0f - float(level - mobLevel) / zeroDifference(level));
}

/// Where a kill is, for its elites' experience.
enum KillPlace : ubyte
{
    world,   /// the open world (and battlegrounds)
    dungeon, /// a five-player instance
    raid,    /// a raid instance
}

/// What `killGain` needs of the creature.
struct KillValue
{
    uint level;
    bool elite;          /// rank neither normal nor rare
    KillPlace place;
    float multiplier = 1; /// `ExperienceMultiplier`
    bool noXp;           /// a critter, `NO_XP`, a pet or a totem
}

/**
 * What an elite is worth against a normal creature: double (Wowpedia "Mob experience": "Elite XP = 2 * XP"),
 * two and a half in a five-player instance (the same page: "Mobs in 5-man instances give slightly more XP",
 * "elites in instances give 2.5 * XP when solo-ed"). Raids: double, no source found (docs/FORMULAS.md).
 */
float eliteFactor(KillPlace place) pure nothrow @nogc @safe
{
    return place == KillPlace.dungeon ? 2.5f : 2.0f;
}

/// The experience a kill gives a player of `level` (kill rate 1, no damage by others).
uint killGain(uint level, const KillValue creature) pure nothrow @nogc @safe
{
    import std.math : nearbyint;

    if (creature.noXp)
        return 0;
    float gain = baseGain(level, creature.level);
    if (gain == 0)
        return 0;
    if (creature.elite)
        gain *= eliteFactor(creature.place);
    gain *= creature.multiplier;
    return cast(uint) nearbyint(gain);
}

/**
 * The group's bonus for its size: Wowpedia "Mob experience" for a party (1, 1, 1.166, 1.3, 1.4). A raid group
 * loses experience ("Raid-sized groups dramatically decrease experience gained"), by how much no source says:
 * 1 - 0.05 a member is CMaNGOS's.
 */
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

/**
 * Rest: 5% of a level for every 8 hours resting, at most 150% of a level (Wowpedia "Experience point": "One bubble of
 * rested XP (5% of your current level) is earned for every 8 hours spent resting. A maximum of 30 bubbles (150% of
 * your current level)"; Exhaustion.dbc's Rested row: 8 inn hours, factor 2). Logged out outside an inn or a city it
 * comes at a quarter of that (Wowpedia "Rest"). A kill doubled while it lasts spends its whole gain from that
 * distance, so the rest is kept here as the bonus left, half of it: the client shows `PLAYER_REST_STATE_EXPERIENCE`
 * doubled (CMaNGOS's note: "Client automatically double the value sent"), its rested mark a level and a half on.
 */
float restEarned(long seconds, uint nextLevelXp, float rate = 1) pure nothrow @nogc @safe
{
    enum long eightHours = 8 * 3600;
    return seconds * (nextLevelXp * 0.05f / 2 / eightHours) * rate;
}

/// ditto: the most rested bonus a player of a level can hold.
float restCap(uint nextLevelXp) pure nothrow @nogc @safe
{
    return nextLevelXp * 1.5f / 2;
}

/**
 * The rested bonus of a kill worth `xp` with `rest` left: as much again, never more than is left
 * (Wowpedia "Mob experience": "Rested XP = 2 * XP", "Your bonus on a kill will never exceed the amount ... stored").
 */
uint restedBonus(uint xp, float rest) pure nothrow @nogc @safe
{
    const stored = rest > 0 ? cast(uint) rest : 0;
    return xp < stored ? xp : stored;
}

/// ditto: the rest left after it (Wowpedia "Rest": "The amount of rested bonus consumed is equal to the total amount
/// of XP gained", the whole distance; half of it, the bonus, here).
float restAfterKill(uint xp, float rest) pure nothrow @nogc @safe
{
    const left = rest - restedBonus(xp, rest);
    return left > 0 ? left : 0;
}

/// Group members farther than this from a kill share none of it.
enum float groupXpDistance = 74;

unittest
{
    // Same level: 45 + 5 * level.
    assert(killGain(1, KillValue(1)) == 50 && killGain(10, KillValue(10)) == 95);
    // Higher: 5% a level, at most four.
    assert(killGain(10, KillValue(12)) == 104 && killGain(10, KillValue(20)) == 114); // 104.5: to even
    // Lower: down to nothing at the grey level.
    assert(killGain(10, KillValue(8)) == 68 && killGain(10, KillValue(4)) == 0); // 95 * (1 - 2/7)
    assert(grayLevel(10) == 4 && grayLevel(20) == 13 && grayLevel(50) == 39 && grayLevel(60) == 47);
    assert(isGray(60, 47) && !isGray(60, 48) && isGray(10, 4) && !isGray(10, 5));
    // Elites: double in the world and in raids, two and a half in a dungeon; a multiplier.
    assert(killGain(10, KillValue(10, true)) == 190 && killGain(10, KillValue(10, true, KillPlace.raid)) == 190);
    assert(killGain(10, KillValue(10, true, KillPlace.dungeon)) == 238);
    assert(killGain(10, KillValue(10, false, KillPlace.world, 0.5f)) == 48);
    assert(killGain(10, KillValue(10, false, KillPlace.world, 1, true)) == 0);
    // Wowpedia's (2008) duo examples: the solo XP of a level 35 on a level 30, of a 36 on a 34.
    assert(killGain(35, KillValue(30)) == 128 && baseGain(36, 34) == 187.5f);
    // Rest: 5% a level each 8 hours, 150% at most, kept as the bonus (half); a kill spends its bonus from it.
    assert(restEarned(8 * 3600, 1000) == 25 && restCap(1000) == 750);
    assert(restedBonus(86, 1000) == 86 && restAfterKill(86, 1000) == 1000 - 86);
    assert(restedBonus(86, 2) == 2 && restAfterKill(86, 2) == 0, "a bonus no more than is stored");
    assert(groupRate(2) == 1 && groupRate(3) == 1.166f && groupRate(5) == 1.4f);
}
