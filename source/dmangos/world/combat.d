/**
 * Melee combat: CMaNGOS's `Unit` melee formulas (`Entities/Unit.cpp`: `CalculateMeleeDamage`,
 * `RollMeleeOutcomeAgainst`, the `CalculateEffective*Chance` family, `CalcArmorReducedDamage`,
 * `CanReachWithMeleeAttack`) and the packets of an attack (`SendAttackStateUpdate`,
 * `SendMeleeAttackStart`, `SendMeleeAttackStop`).
 *
 * A fighter, player or creature, is described by a `Fighter`: what the formulas need of it as it
 * is now. There are no auras yet, so every aura modifier is zero: no hit or crit bonuses, no
 * absorbs or resists, no immunities, no damage shields.
 */
module dmangos.world.combat;

import std.math : atan2, PI, round;
import std.random : Random, uniform;

import dmangos.bytes : ByteWriter;
import dmangos.world.movement : Position;
public import dmangos.world.stats : AttackType;

/// `HitInfo`
enum HitInfo : uint
{
    normalSwing = 0x00000000,
    normalSwing2 = 0x00000002,
    leftSwing = 0x00000004,
    miss = 0x00000010,
    absorb = 0x00000020,
    resist = 0x00000040,
    criticalHit = 0x00000080,
    block = 0x00000800,
    glancing = 0x00004000,
    crushing = 0x00008000,
    noAction = 0x00010000,
    swingNoHitSound = 0x00080000,
}

/// `VictimState`
enum VictimState : uint
{
    unaffected = 0,
    normal = 1,
    dodge = 2,
    parry = 3,
    interrupt = 4,
    blocks = 5,
    evades = 6,
    isImmune = 7,
    deflects = 8,
}

/// `MeleeHitOutcome`
enum MeleeHitOutcome : ubyte
{
    evade,
    miss,
    dodge,
    block,
    parry,
    glancing,
    crit,
    crushing,
    normal,
}

/// `SwingError`: why a swing did not happen, as the client is told.
enum SwingError : ubyte
{
    none,
    notInRange,
    badFacing,
    cantAttack,
    targetNotAlive,
}

/// `ATTACK_DISTANCE`, `BASE_MELEERANGE_OFFSET`, `MELEE_LEEWAY`
enum float attackDistance = 5.0f, baseMeleeRangeOffset = 1.33f, meleeLeeway = 8.0f / 3.0f;

/// `ATTACK_DISPLAY_DELAY`: milliseconds between a main hand and an off hand swing.
enum uint attackDisplayDelay = 200;

/// `CONFIG_UINT32_WORLD_BOSS_LEVEL_DIFF`: a world boss is this much above whoever it fights.
enum uint worldBossLevelDiff = 3;

/// What the melee formulas need of a player or a creature, as it is now.
struct Fighter
{
    ulong guid;
    bool player;               /// `TYPEID_PLAYER`
    bool playerControlled;     /// `UNIT_FLAG_PLAYER_CONTROLLED`
    bool worldBoss;            /// a creature of rank 3: its level is that of its target plus 3
    uint level;
    ubyte classId;             /// a player's (casters glance less)
    Position position;         /// with its orientation
    float combatReach = 1.5f;  /// `UNIT_FIELD_COMBATREACH`
    bool runningAround;        /// moving, and not walking (`IsMoving() && !IsWalking()`)
    bool alive = true;
    bool standing = true;      /// `IsStandState`: a player not standing is hit critically
    bool evading;              /// a creature returning home after a fight

    // What it attacks with.
    uint[3] weaponSkill;       /// a player's current skill, by attack type
    uint[3] weaponSkillMax;    /// a player's maximum (against players, the higher counts)
    float[2][3] damage = 0;    /// by attack type: minimum, maximum (`UNIT_FIELD_MINDAMAGE`, ...)
    uint[3] damageSchool;      /// by attack type: the school index (0: physical)
    float crit = 0;            /// `GetCritChance`: a player's from agility; a creature's 5
    bool dualWield;            /// `hasOffhandWeaponForAttack`

    // What it defends with.
    uint defenseSkill, defenseSkillMax; /// a player's
    float dodge = 0, parry = 0, block = 0; /// `GetDodgeChance` ...: a player's own; a creature's 5 each
    bool canDodge = true, canParry, canBlock; /// able at all: Parry known and a weapon, Block and a shield
    uint shieldBlock;          /// `GetShieldBlockValue`
    uint armor;
}

// ---------------------------------------------------------------------------
// Levels and skills
// ---------------------------------------------------------------------------

/// `GetLevelForTarget`: a world boss counts as above its target.
uint levelFor(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    if (!self.worldBoss)
        return self.level;
    const level = target.level + worldBossLevelDiff;
    return level > 255 ? 255 : level;
}

/// `GetSkillMaxForLevel`
uint skillMaxForLevel(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    return levelFor(self, target) * 5;
}

/// `GetSkillMaxForLevel` without a target.
uint skillMaxForLevel(const Fighter self) pure nothrow @nogc @safe
{
    return self.level * 5;
}

/// `GetWeaponSkillValue`: against players a player uses the higher of its skill and maximum.
uint weaponSkillValue(const Fighter self, AttackType type, const Fighter target) pure nothrow @nogc @safe
{
    if (!self.player)
        return levelFor(self, target) * 5; // `GetUnitMeleeSkill`
    const value = self.weaponSkill[type];
    return target.player && self.weaponSkillMax[type] > value ? self.weaponSkillMax[type] : value;
}

/// `GetDefenseSkillValue`
uint defenseSkillValue(const Fighter self, const Fighter attacker) pure nothrow @nogc @safe
{
    if (!self.player)
        return levelFor(self, attacker) * 5;
    return attacker.player && self.defenseSkillMax > self.defenseSkill ? self.defenseSkillMax : self.defenseSkill;
}

// ---------------------------------------------------------------------------
// Where they stand
// ---------------------------------------------------------------------------

/// `WorldObject::HasInArc`: whether `target` is within `arc` radians of where `self` faces.
bool hasInArc(Position self, Position target, float arc = PI) pure nothrow @nogc @safe
{
    if (self.x == target.x && self.y == target.y)
        return true;
    float normalize(float o) { o = o % (2 * PI); return o < 0 ? o + 2 * PI : o; }
    arc = normalize(arc);
    float angle = normalize(atan2(target.y - self.y, target.x - self.x)) - self.orientation;
    angle = normalize(angle);
    if (angle > PI)
        angle -= 2 * PI;
    return angle >= -arc / 2 && angle <= arc / 2;
}

/// `IsFacingTargetsFront`: each in front of the other.
bool isFacingFront(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    return hasInArc(target.position, self.position) && hasInArc(self.position, target.position);
}

/// `IsFacingTargetsBack`: facing the target, which faces away.
bool isFacingBack(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    return !hasInArc(target.position, self.position) && hasInArc(self.position, target.position);
}

/// `GetCombinedCombatReach` for melee: both reaches and the offset, at least `ATTACK_DISTANCE`.
float meleeReach(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    const reach = self.combatReach + target.combatReach + baseMeleeRangeOffset;
    return reach < attackDistance ? attackDistance : reach;
}

/// `CanReachWithMeleeAttack`: players measure in three dimensions, creatures on the ground.
bool canReachWithMelee(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    float reach = meleeReach(self, target);
    if (self.runningAround && target.runningAround)
        reach += meleeLeeway;
    const dx = self.position.x - target.position.x, dy = self.position.y - target.position.y;
    if (self.playerControlled)
    {
        const dz = self.position.z - target.position.z;
        return dx * dx + dy * dy + dz * dz < reach * reach;
    }
    return dx * dx + dy * dy < reach * reach;
}

// ---------------------------------------------------------------------------
// Chances (in percent)
// ---------------------------------------------------------------------------

private float clamp100(float chance) pure nothrow @nogc @safe
{
    return chance < 0 ? 0 : chance > 100 ? 100 : chance;
}

/// `CalculateEffectiveMissChance`: 5%, more for dual wielding and better defense, less for skill.
float missChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    float chance = 5; // `GetMissChance`: totems aside, everyone is missed 5% of the time
    if (type != AttackType.ranged && attacker.dualWield)
        chance += 19;
    int difference = int(defenseSkillValue(victim, attacker)) - int(weaponSkillValue(attacker, type, victim));
    float factor = 0.04f;
    if (!victim.playerControlled && difference > 0)
    {
        if (difference > 10)
        {
            chance += 10 * 0.1f;
            difference -= 10;
            factor = 0.4f;
            chance += difference * 0.2f;
        }
        else
            factor = 0.1f;
    }
    chance += difference * factor;
    const minimum = difference > 10 ? 1.0f : 0.0f;
    return chance < minimum ? minimum : chance > 100 ? 100 : chance;
}

/// `CalculateEffectiveDodgeChance`
float dodgeChance(const Fighter victim, const Fighter attacker, AttackType type) pure nothrow @nogc @safe
{
    float chance = victim.dodge;
    if (chance < 0.005f)
        return 0;
    const difference = int(defenseSkillValue(victim, attacker)) - int(weaponSkillValue(attacker, type, victim));
    const factor = !victim.playerControlled && difference > 0 ? 0.1f : 0.04f;
    return clamp100(chance + difference * factor);
}

/// `CalculateEffectiveParryChance`
float parryChance(const Fighter victim, const Fighter attacker, AttackType type) pure nothrow @nogc @safe
{
    if (type == AttackType.ranged)
        return 0;
    float chance = victim.parry;
    if (chance < 0.005f)
        return 0;
    const difference = int(defenseSkillValue(victim, attacker)) - int(weaponSkillValue(attacker, type, victim));
    float factor = 0.04f;
    if (!victim.playerControlled && difference > 0)
        factor = difference > 10 ? 0.6f : 0.1f;
    return clamp100(chance + difference * factor);
}

/// `CalculateEffectiveBlockChance`
float blockChance(const Fighter victim, const Fighter attacker, AttackType type) pure nothrow @nogc @safe
{
    float chance = victim.block;
    if (chance < 0.005f)
        return 0;
    const difference = int(defenseSkillValue(victim, attacker)) - int(weaponSkillValue(attacker, type, victim));
    const factor = !victim.playerControlled && difference > 0 ? 0.0f : 0.04f;
    return clamp100(chance + difference * factor);
}

/// `CalculateEffectiveCrushChance`: 15% and 2% a point when the weapon beats the capped defense by 15.
float crushChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    const cap = skillMaxForLevel(victim);
    auto defense = defenseSkillValue(victim, attacker);
    if (defense > cap)
        defense = cap;
    const deficit = int(weaponSkillValue(attacker, type, victim)) - int(defense);
    return deficit >= 15 ? clamp100(2 * deficit - 15) : 0;
}

/// `CalculateEffectiveGlanceChance`: from 10% up with the victim's defense over the capped skill.
float glanceChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    const cap = skillMaxForLevel(attacker);
    auto skill = weaponSkillValue(attacker, type, victim);
    if (skill > cap)
        skill = cap;
    const level = int(levelFor(attacker, victim));
    const difference = int(defenseSkillValue(victim, attacker)) - int(skill);
    float chance;
    if (attacker.player && isWandUser(attacker.classId))
        chance = (level < 30 ? level : 30) + difference * 2;
    else
        chance = 10 + difference * 2;
    return clamp100(chance);
}

/// `CalculateEffectiveCritChance`: against creatures, 1% less for each level above the attacker.
float critChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    float chance = attacker.crit;
    if (chance < 0.005f)
        return 0;
    const vsPlayer = victim.playerControlled;
    const skill = !vsPlayer ? weaponSkillValue(attacker, type, victim) : skillMaxForLevel(attacker, victim);
    const difference = int(skill) - int(defenseSkillValue(victim, attacker));
    chance += difference * (vsPlayer ? 0.04f : 0.2f);
    return clamp100(chance);
}

/// `CLASSMASK_WAND_USERS`: priests, mages and warlocks.
private bool isWandUser(ubyte classId) pure nothrow @nogc @safe
{
    return classId == 5 || classId == 8 || classId == 9;
}

/// `CanDodgeInCombat(attacker)`: a player dodges only what comes from the front.
private bool canDodge(const Fighter victim, const Fighter attacker) pure nothrow @nogc @safe
{
    if (!victim.canDodge || victim.dodge < 0.005f)
        return false;
    return !victim.player || isFacingFront(attacker, victim);
}

/// `CanParryInCombat(attacker)`: only from the front.
private bool canParry(const Fighter victim, const Fighter attacker) pure nothrow @nogc @safe
{
    return victim.canParry && victim.parry >= 0.005f && isFacingFront(attacker, victim);
}

/// `CanBlockInCombat(attacker)`: physical attacks from the front.
private bool canBlock(const Fighter victim, const Fighter attacker, uint school) pure nothrow @nogc @safe
{
    return school == 0 && victim.canBlock && victim.block >= 0.005f && isFacingFront(attacker, victim);
}

/// `chance_u`: a chance in hundredths of a percent, rounded.
private uint hundredths(float chance) pure nothrow @nogc @safe
{
    return chance <= 0 ? 0 : cast(uint) round(chance * 100);
}

/**
 * `RollMeleeOutcomeAgainst`: the attack table, one roll (`random`, 1 to 10000) through miss, dodge,
 * parry, block, glance, crit and crush in that order; a hit if it goes past them all.
 */
MeleeHitOutcome rollMeleeOutcome(const Fighter attacker, const Fighter victim, AttackType type, uint random)
    pure nothrow @nogc @safe
{
    if (victim.evading)
        return MeleeHitOutcome.evade;
    uint[7] chance; // miss, dodge, parry, block, glance, crit, crush
    chance[0] = hundredths(missChance(attacker, victim, type));
    if (victim.player && !victim.standing)
        chance[5] = 10_000; // a player sitting down is always hit critically
    else
    {
        if (canDodge(victim, attacker))
            chance[1] = hundredths(dodgeChance(victim, attacker, type));
        if (canParry(victim, attacker))
            chance[2] = hundredths(parryChance(victim, attacker, type));
        if (canBlock(victim, attacker, attacker.damageSchool[type]))
            chance[3] = hundredths(blockChance(victim, attacker, type));
        // Players glance against creatures above level 10; creatures crush players.
        if (attacker.playerControlled && !victim.playerControlled && levelFor(victim, attacker) > 10)
            chance[4] = hundredths(glanceChance(attacker, victim, type));
        chance[5] = hundredths(critChance(attacker, victim, type));
        if (!attacker.playerControlled && victim.playerControlled)
            chance[6] = hundredths(crushChance(attacker, victim, type));
    }
    static immutable MeleeHitOutcome[7] sides = [MeleeHitOutcome.miss, MeleeHitOutcome.dodge, MeleeHitOutcome.parry,
        MeleeHitOutcome.block, MeleeHitOutcome.glancing, MeleeHitOutcome.crit, MeleeHitOutcome.crushing];
    uint rolling;
    foreach (i, c; chance)
        if (c)
        {
            rolling += c;
            if (random <= rolling)
                return sides[i];
        }
    return MeleeHitOutcome.normal;
}

// ---------------------------------------------------------------------------
// Damage
// ---------------------------------------------------------------------------

/// `CalcDamageInfo`: one swing worked out.
struct MeleeDamage
{
    ulong attacker, target;
    AttackType type;
    uint hitInfo;              /// `HitInfo` flags
    VictimState targetState;
    MeleeHitOutcome outcome;
    uint school;               /// the school index of its one damage line
    uint damage;               /// what the victim takes
    uint cleanDamage;          /// before blocks and glances (rage from damage taken uses it)
    uint blocked;
}

/// `CalcArmorReducedDamage`: armor takes up to 75%, less against higher levels.
float armorReducedDamage(uint attackerLevel, uint armor, float damage) pure nothrow @nogc @safe
{
    float reduction = 0.1f * armor / (8.5f * attackerLevel + 40);
    reduction = reduction / (1.0f + reduction);
    if (reduction < 0)
        reduction = 0;
    if (reduction > 0.75f)
        reduction = 0.75f;
    const reduced = damage - damage * reduction;
    return reduced > 1 ? reduced : 1;
}

/// `CalculateDamage`: a whole number between the weapon's minimum and maximum (5 if it has none).
uint weaponDamage(const Fighter attacker, AttackType type, ref Random rng) @safe
{
    float low = attacker.damage[type][0], high = attacker.damage[type][1];
    if (low > high)
    {
        const t = low;
        low = high;
        high = t;
    }
    if (high == 0)
        high = 5;
    return uniform!"[]"(cast(uint) low, cast(uint) high, rng);
}

/// `CalculateGlanceAmount`: a glancing blow does 1% to 99% of the damage, less the better the defense.
uint glanceAmount(const Fighter attacker, const Fighter victim, AttackType type, uint damage, ref Random rng) @safe
{
    const skill = weaponSkillValue(attacker, type, victim);
    const difference = int(defenseSkillValue(victim, attacker)) - int(skill);
    if (difference < 0)
        return damage;
    const caster = isWandUser(attacker.classId) && attacker.player;
    const baseHighEnd = caster ? 0.9f : 1.2f, baseLowEnd = caster ? 0.6f : 1.3f, maxLowEnd = caster ? 0.6f : 0.91f;
    float highEnd = baseHighEnd - 0.03f * difference;
    float lowEnd = baseLowEnd - 0.05f * difference;
    highEnd = highEnd < 0.2f ? 0.2f : highEnd > 0.99f ? 0.99f : highEnd;
    const lowCap = maxLowEnd < highEnd ? maxLowEnd : highEnd;
    lowEnd = lowEnd < 0.01f ? 0.01f : lowEnd > lowCap ? lowCap : lowEnd;
    const multiplier = uniform!"[]"(cast(uint)(lowEnd * 100), cast(uint)(highEnd * 100), rng) * 0.01f;
    return cast(uint)(damage * multiplier);
}

/**
 * `CalculateMeleeDamage`: the weapon's damage less armor (for physical attacks), then the attack
 * table's outcome: nothing for a miss, dodge or parry, double for a crit, less what the shield
 * stops for a block, less for a glance, half again for a crushing blow.
 */
MeleeDamage calculateMeleeDamage(const Fighter attacker, const Fighter victim, AttackType type, ref Random rng)
    @safe
{
    MeleeDamage d;
    d.attacker = attacker.guid;
    d.target = victim.guid;
    d.type = type;
    d.school = attacker.damageSchool[type];
    d.outcome = MeleeHitOutcome.evade;
    if (!attacker.alive || !victim.alive)
        return d;
    d.hitInfo = type == AttackType.offHand ? HitInfo.leftSwing : HitInfo.normalSwing2;

    float damage = weaponDamage(attacker, type, rng);
    if (d.school == 0)
        damage = armorReducedDamage(attacker.level, victim.armor, damage);
    d.damage = cast(uint) damage;
    d.cleanDamage = d.damage;

    d.outcome = rollMeleeOutcome(attacker, victim, type, uniform!"[]"(1, 10_000, rng));
    final switch (d.outcome)
    {
    case MeleeHitOutcome.evade:
        d.hitInfo |= HitInfo.miss | HitInfo.swingNoHitSound;
        d.targetState = VictimState.evades;
        d.damage = d.cleanDamage = 0;
        return d;
    case MeleeHitOutcome.miss:
        d.hitInfo |= HitInfo.miss;
        d.targetState = VictimState.unaffected;
        d.damage = d.cleanDamage = 0;
        break;
    case MeleeHitOutcome.normal:
        d.targetState = VictimState.normal;
        break;
    case MeleeHitOutcome.crit:
        d.hitInfo |= HitInfo.criticalHit;
        d.targetState = VictimState.normal;
        d.damage *= 2; // `GetCritMultiplier`: 2 for attacks
        break;
    case MeleeHitOutcome.parry:
        d.targetState = VictimState.parry;
        d.cleanDamage += d.damage;
        d.damage = 0;
        break;
    case MeleeHitOutcome.dodge:
        d.targetState = VictimState.dodge;
        d.cleanDamage += d.damage;
        d.damage = 0;
        break;
    case MeleeHitOutcome.block:
        d.hitInfo |= HitInfo.block;
        d.targetState = VictimState.normal;
        d.blocked = victim.shieldBlock;
        if (d.blocked >= d.damage)
        {
            d.targetState = VictimState.blocks;
            d.blocked = d.damage;
        }
        d.damage -= d.blocked;
        d.cleanDamage += d.blocked;
        break;
    case MeleeHitOutcome.glancing:
        d.hitInfo |= HitInfo.glancing;
        d.targetState = VictimState.normal;
        const glanced = glanceAmount(attacker, victim, type, d.damage, rng);
        d.cleanDamage += d.damage - glanced;
        d.damage = glanced;
        break;
    case MeleeHitOutcome.crushing:
        d.hitInfo |= HitInfo.crushing;
        d.targetState = VictimState.normal;
        d.damage += d.damage / 2;
        break;
    }
    return d;
}

/// `Player::RewardRage`: rage (in tenths, as the power field holds it) for melee damage dealt or taken.
uint rageReward(uint level, uint damage, bool dealt) pure nothrow @nogc @safe
{
    const conversion = cast(float)(0.0091107836 * level * level + 3.225598133 * level) + 4.2652911f;
    const rage = damage / conversion * (dealt ? 7.5f : 2.5f);
    return cast(uint)(rage * 10);
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------

/// `SMSG_ATTACKERSTATEUPDATE` (`SendAttackStateUpdate`): one damage line, no debug block.
const(ubyte)[] attackerStateUpdate(const ref MeleeDamage d)
{
    ByteWriter w;
    w.put(d.hitInfo);
    w.putPackedGuid(d.attacker);
    w.putPackedGuid(d.target);
    w.put(d.damage);
    w.put(ubyte(1));
    w.put(d.school);
    w.put(float(d.damage));
    w.put(d.damage);
    w.put(uint(0)); // absorbed
    w.put(int(0));  // resisted
    w.put(cast(uint) d.targetState);
    w.put(uint(0));
    w.put(uint(0)); // spell id
    w.put(d.blocked);
    return w.data;
}

/// `SMSG_ATTACKSTART` (`SendMeleeAttackStart`)
const(ubyte)[] attackStart(ulong attacker, ulong victim)
{
    ByteWriter w;
    w.put(attacker);
    w.put(victim);
    return w.data;
}

/// `SMSG_ATTACKSTOP` (`SendMeleeAttackStop`): `victim` 0 for none; `dead` says the attacker died.
const(ubyte)[] attackStop(ulong attacker, ulong victim, bool dead)
{
    ByteWriter w;
    w.putPackedGuid(attacker);
    w.putPackedGuid(victim);
    w.put(uint(victim && dead ? 1 : 0));
    return w.data;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    /// A level `level` player facing east at (0, 0), and a creature in front of it, facing it.
    Fighter testPlayer(uint level)
    {
        Fighter p;
        p.guid = 1;
        p.player = p.playerControlled = true;
        p.level = level;
        p.classId = 1;
        p.weaponSkill = p.weaponSkillMax = [level * 5, 0, 0];
        p.defenseSkill = p.defenseSkillMax = level * 5;
        p.damage[0] = [10, 20];
        p.crit = 5;
        p.dodge = 5;
        return p;
    }

    Fighter testCreature(uint level)
    {
        Fighter c;
        c.guid = 0xF130_0000_0000_0001;
        c.level = level;
        c.position = Position(2, 0, 0, PI);
        c.damage[0] = [5, 8];
        c.crit = c.dodge = c.parry = c.block = 5;
        c.canParry = c.canBlock = true;
        return c;
    }
}

/// The attack table against a creature of the same level, and as levels part.
unittest
{
    auto player = testPlayer(10);
    auto wolf = testCreature(10);
    assert(missChance(player, wolf, AttackType.mainHand) == 5);
    assert(dodgeChance(wolf, player, AttackType.mainHand) == 5 && parryChance(wolf, player, AttackType.mainHand) == 5);
    assert(critChance(player, wolf, AttackType.mainHand) == 5);
    assert(glanceChance(player, wolf, AttackType.mainHand) == 10);

    // Three levels above: 15 points of defense over the skill.
    wolf.level = 13;
    const miss = missChance(player, wolf, AttackType.mainHand);
    assert(miss > 5 + 1 + 1 + 1.99f && miss < 5 + 1 + 1 + 2.01f, "1% for the first 10 points, then 0.6% a point");
    const crit = critChance(player, wolf, AttackType.mainHand);
    assert(crit > 1.99f && crit < 2.01f, "crit 1% less per level against creatures");
    assert(glanceChance(player, wolf, AttackType.mainHand) == 40);

    // The table, in order: a low roll misses; one past miss, dodge and parry is a block; past everything, a hit.
    wolf.level = 10;
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 1) == MeleeHitOutcome.miss);
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 501) == MeleeHitOutcome.dodge);
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 1001) == MeleeHitOutcome.parry);
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 1501) == MeleeHitOutcome.block);
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 2001) == MeleeHitOutcome.crit, "no glances at level 10");
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 2501) == MeleeHitOutcome.normal);

    // From behind the creature: it neither parries nor blocks (it still dodges: it is not a player).
    wolf.position.orientation = 0;
    assert(rollMeleeOutcome(player, wolf, AttackType.mainHand, 1001) == MeleeHitOutcome.crit);

    // A creature against a sitting player: every hit not missed is a crit.
    auto sitting = testPlayer(10);
    sitting.standing = false;
    wolf.position.orientation = PI;
    assert(rollMeleeOutcome(wolf, sitting, AttackType.mainHand, 600) == MeleeHitOutcome.crit);
}

/// Damage: armor, crits, blocks, and an evading victim.
unittest
{
    assert(armorReducedDamage(10, 0, 100) == 100);
    const reduced = armorReducedDamage(10, 400, 100);
    assert(reduced > 75.7f && reduced < 75.8f, "0.1 * 400 / (85 + 40) = 0.32, 0.32 / 1.32 = 24.2% less");
    assert(armorReducedDamage(1, 100_000, 100) == 25, "at most 75%");

    auto rng = Random(7);
    auto player = testPlayer(10);
    auto wolf = testCreature(10);
    foreach (_; 0 .. 200)
    {
        const d = calculateMeleeDamage(player, wolf, AttackType.mainHand, rng);
        final switch (d.outcome)
        {
        case MeleeHitOutcome.normal:
            assert(d.damage >= 10 && d.damage <= 20 && d.targetState == VictimState.normal);
            break;
        case MeleeHitOutcome.crit:
            assert(d.damage >= 20 && d.damage <= 40 && (d.hitInfo & HitInfo.criticalHit));
            break;
        case MeleeHitOutcome.miss, MeleeHitOutcome.dodge, MeleeHitOutcome.parry:
            assert(d.damage == 0);
            break;
        case MeleeHitOutcome.block:
            assert(d.damage + d.blocked >= 10 && (d.hitInfo & HitInfo.block));
            break;
        case MeleeHitOutcome.glancing, MeleeHitOutcome.crushing, MeleeHitOutcome.evade:
            assert(0, "not against a level 10 creature");
        }
    }
    wolf.evading = true;
    const evaded = calculateMeleeDamage(player, wolf, AttackType.mainHand, rng);
    assert(evaded.outcome == MeleeHitOutcome.evade && evaded.targetState == VictimState.evades && evaded.damage == 0);

    // Rage: a level 1 warrior hitting for 10 gets 10 / 7.49 * 7.5 = 10.0 rage, 100 in the field.
    const rage = rageReward(1, 10, true);
    assert(rage >= 99 && rage <= 101);
}

/// Reach and facing.
unittest
{
    auto player = testPlayer(10);
    auto wolf = testCreature(10);
    assert(canReachWithMelee(player, wolf) && meleeReach(player, wolf) == attackDistance);
    wolf.position.x = 5.1f;
    assert(!canReachWithMelee(player, wolf));
    player.runningAround = wolf.runningAround = true;
    assert(canReachWithMelee(player, wolf), "both running: the leeway");

    assert(hasInArc(Position(0, 0, 0, 0), Position(3, 1, 0), 2 * PI / 3));
    assert(!hasInArc(Position(0, 0, 0, 0), Position(-3, 0, 0), 2 * PI / 3), "behind");
    assert(!hasInArc(Position(0, 0, 0, PI / 2), Position(3, 0, 0), 2 * PI / 3), "to the side");
}

/// The packets.
unittest
{
    MeleeDamage d;
    d.attacker = 1;
    d.target = 0xF130_0000_0000_0001;
    d.hitInfo = HitInfo.normalSwing2 | HitInfo.criticalHit;
    d.damage = 42;
    d.targetState = VictimState.normal;
    const update = attackerStateUpdate(d);
    // hit info, packed guids (mask and 1 byte; mask and 3), total, one line (school, float, whole, absorb, resist),
    // state, two zeros, blocked
    assert(update.length == 4 + 2 + 4 + 4 + 1 + 20 + 4 + 4 + 4 + 4);
    assert(update[0 .. 4] == [0x82, 0, 0, 0] && update[10] == 42);
    assert(attackStart(1, 2).length == 16);
    assert(attackStop(1, 0, true)[$ - 4 .. $] == [0, 0, 0, 0], "no victim: no death flag");
}
