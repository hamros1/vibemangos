/**
 * Melee combat: the melee formulas (reach, the chances of the attack table and the roll through it,
 * weapon damage, armor, glancing and crushing blows, rage) and the packets of an attack
 * (`SMSG_ATTACKERSTATEUPDATE`, `SMSG_ATTACKSTART`, `SMSG_ATTACKSTOP`), and spells' partial resists.
 *
 * A fighter, player or creature, is described by a `Fighter`: what the formulas need of it as it
 * is now, its auras' crit, dodge, parry, block and hit bonuses included. Shields' absorbs are taken
 * off by the callers before the log is sent; there are no immunities or damage shields here.
 */
module dmangos.world.combat;

import std.math : atan2, PI, round;
import std.random : Random, uniform;

import dmangos.bytes : ByteWriter;
import dmangos.world.movement : Position;
public import dmangos.world.stats : AttackType;

/// Flags of a swing in `SMSG_ATTACKERSTATEUPDATE`.
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

/// What happened to the victim of a swing, as `SMSG_ATTACKERSTATEUPDATE` says.
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

/// The attack table's outcome of a swing.
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

/// Why a swing did not happen, as the client is told.
enum SwingError : ubyte
{
    none,
    notInRange,
    badFacing,
    cantAttack,
    targetNotAlive,
}

/// The least melee reach, the offset added to both reaches, and the leeway of a moving pair (yards).
enum float attackDistance = 5.0f, baseMeleeRangeOffset = 1.33f, meleeLeeway = 8.0f / 3.0f;

/// Milliseconds between a main hand and an off hand swing.
enum uint attackDisplayDelay = 200;

/// A world boss is this much above whoever it fights.
enum uint worldBossLevelDiff = 3;

/// What the melee formulas need of a player or a creature, as it is now.
struct Fighter
{
    ulong guid;
    bool player;               /// a player, not a creature
    bool playerControlled;     /// `UNIT_FLAG_PLAYER_CONTROLLED`
    bool worldBoss;            /// a creature of rank 3: its level is that of its target plus 3
    uint level;
    ubyte classId;             /// a player's (casters glance less)
    Position position;         /// with its orientation
    float combatReach = 1.5f;  /// `UNIT_FIELD_COMBATREACH`
    bool runningAround;        /// moving, and not walking
    bool alive = true;
    bool standing = true;      /// standing up: a player not standing is hit critically
    bool evading;              /// a creature returning home after a fight

    // What it attacks with.
    uint[3] weaponSkill;       /// a player's current skill, by attack type
    uint[3] weaponSkillMax;    /// a player's maximum (against players, the higher counts)
    float[2][3] damage = 0;    /// by attack type: minimum, maximum (`UNIT_FIELD_MINDAMAGE`, ...)
    uint[3] damageSchool;      /// by attack type: the school index (0: physical)
    float crit = 0;            /// its crit chance: a player's from agility; a creature's 5
    float hitBonus = 0;        /// percent less often missed (`MOD_HIT_CHANCE` auras)
    bool dualWield;            /// it has an off-hand weapon to attack with
    float[3] damageDone = 1;   /// by attack type: what its auras multiply its blows by (`MOD_DAMAGE_PERCENT_DONE`)
    float[creatureTypes] damageVersus = 1; /// by the victim's creature type (`MOD_DAMAGE_DONE_VERSUS`)
    float[creatureTypes] critVersus = 0;   /// crit percent more by the victim's type (`MOD_CRIT_PERCENT_VERSUS`)

    // What it defends with.
    uint defenseSkill, defenseSkillMax; /// a player's
    float dodge = 0, parry = 0, block = 0; /// its chances: a player's own; a creature's 5 each
    bool canDodge = true, canParry, canBlock; /// able at all: Parry known and a weapon, Block and a shield
    uint shieldBlock;          /// what its shield stops of a blocked blow
    uint armor;
    float[7] damageTaken = 1;  /// by school: what its auras multiply blows against it by (`MOD_DAMAGE_PERCENT_TAKEN`)
    int[7] damageTakenFlat;    /// by school: what its auras add to each blow first (`MOD_DAMAGE_TAKEN`: Blessing of Sanctuary)
    Immunities immune;         /// what cannot touch it
    /// What its auras do to its attackers' chances (melee, ranged, spell): crits against it (`MOD_ATTACKER_*_CRIT_CHANCE`:
    /// Winter's Chill, Sleight of Hand), hits on it (`MOD_ATTACKER_*_HIT_CHANCE`: Heightened Senses).
    float[3] attackerCrit = 0, attackerHit = 0;
    int rangedTakenFlat;       /// `MOD_RANGED_DAMAGE_TAKEN` (Elune's Grace): added to each ranged blow against it

    /// Fills `attackerCrit` and `attackerHit` from `auras`.
    void attackerChancesFrom(A)(const ref A auras)
    {
        import dmangos.world.spellids : AuraType;

        attackerCrit = [auras.total(AuraType.modAttackerMeleeCritChance), auras.total(AuraType.modAttackerRangedCritChance),
            auras.total(AuraType.modAttackerSpellCritChance)];
        attackerHit = [auras.total(AuraType.modAttackerMeleeHitChance), auras.total(AuraType.modAttackerRangedHitChance),
            auras.total(AuraType.modAttackerSpellHitChance)];
        rangedTakenFlat = auras.total(AuraType.modRangedDamageTaken);
    }
    float[mechanics] mechanicResist = 0; /// percent more often it resists spells of each mechanic (`MOD_MECHANIC_RESISTANCE`)
    uint creatureType = creatureTypeHumanoid; /// `CreatureType` (a player is a humanoid)
    bool stealthed;            /// under a `MOD_STEALTH` aura (Stealth, Prowl)
    int stealth;               /// its stealth strength: `MOD_STEALTH` and `MOD_STEALTH_LEVEL` amounts
    int stealthDetect;         /// its detection of stealth: `MOD_STEALTH_DETECT` (misc 0) amounts
}

/// The farthest a player detects a stealthed unit (`MAX_PLAYER_STEALTH_DETECT_RANGE`).
enum float maxPlayerStealthDetectRange = 30;

/**
 * How near `detector` must be to see `stealthed` (CMaNGOS's `GetStealthVisibilityDistance`): 30 points, 5 more
 * for each of the detector's levels above the first and its detection auras, less the stealth's strength; three
 * tenths of a yard a point, at most `maxPlayerStealthDetectRange` for a player; `alert` looks 8% and a yard and a
 * half further (a creature on its guard, not yet seeing). Never less than the stealthed unit's combat reach.
 */
float stealthDetectRange(const Fighter detector, const Fighter stealthed, bool alert = false) pure nothrow @nogc @safe
{
    const value = 30 + (cast(int) levelFor(detector, stealthed) - 1) * 5 + detector.stealthDetect - stealthed.stealth;
    float range = value * 0.3f;
    if (detector.player && range > maxPlayerStealthDetectRange)
        range = maxPlayerStealthDetectRange;
    if (alert)
        range += range * 0.08f + 1.5f;
    return range > stealthed.combatReach ? range : stealthed.combatReach;
}

/**
 * Whether `detector` sees `stealthed` now: always if it is not stealthed; else only in front of the detector,
 * within `stealthDetectRange` (and `maxDistance`, a creature's aggro radius).
 */
bool detects(const Fighter detector, const Fighter stealthed, float maxDistance, bool alert = false)
    pure nothrow @nogc @safe
{
    if (!stealthed.stealthed)
        return true;
    const dx = detector.position.x - stealthed.position.x, dy = detector.position.y - stealthed.position.y,
        dz = detector.position.z - stealthed.position.z;
    const d2 = dx * dx + dy * dy + dz * dz;
    if (d2 > maxDistance * maxDistance || !hasInArc(detector.position, stealthed.position))
        return false;
    const range = stealthDetectRange(detector, stealthed, alert);
    return d2 <= range * range;
}

/**
 * What a unit's auras do to the damage it deals and takes: `MOD_DAMAGE_PERCENT_DONE` (by school, and for a weapon
 * swing only if the aura's spell takes the weapon: Two-Handed Weapon Specialization), `MOD_DAMAGE_DONE_VERSUS` and
 * `MOD_CRIT_PERCENT_VERSUS` (by the victim's creature type), `MOD_DAMAGE_PERCENT_TAKEN` (by school). Percentages
 * of one kind multiply (`AuraSet.multiplier`).
 */
struct DamageMods
{
    float[3] swing = 1;        /// by attack type
    float[7] school = 1;       /// spells, by school
    float[creatureTypes] versus = 1;
    float[creatureTypes] critVersus = 0;
    float[7] taken = 1;
    int[7] takenFlat;          /// `MOD_DAMAGE_TAKEN`, by school
    float[7] threat = 1;       /// by school: what its damage is worth in threat (`MOD_THREAT`)
    float[mechanics] mechanicResist = 0;

    /**
     * From `auras`; `weaponOf(slot)` is the subclass of the weapon in an equipment slot (-1: none), `schoolOf(type)`
     * the school of a swing of that type.
     */
    static DamageMods of(A)(const ref A auras, scope int delegate(ubyte slot) weaponOf,
        scope uint delegate(AttackType) schoolOf)
    {
        import dmangos.world.spellids : AuraType;

        DamageMods m;
        if (auras.list.length == 0)
            return m;
        static immutable ubyte[3] slots = [15, 16, 17]; // main hand, off hand, ranged
        foreach (type; 0 .. 3)
        {
            const school = schoolOf(cast(AttackType) type);
            m.swing[type] = auras.multiplier(AuraType.modDamagePercentDone, (int mask) => (mask & (1 << school)) != 0,
                weaponOf(slots[type]));
        }
        foreach (int s; 0 .. 7)
        {
            m.school[s] = auras.multiplier(AuraType.modDamagePercentDone, (int mask) => (mask & (1 << s)) != 0, -1);
            m.taken[s] = auras.multiplier(AuraType.modDamagePercentTaken, (int mask) => (mask & (1 << s)) != 0);
            m.takenFlat[s] = auras.totalByMiscMask(AuraType.modDamageTaken, 1 << s);
            m.threat[s] = auras.multiplier(AuraType.modThreat, (int mask) => (mask & (1 << s)) != 0);
        }
        foreach (int mechanic; 1 .. cast(int) mechanics)
            m.mechanicResist[mechanic] = auras.totalByMisc(AuraType.modMechanicResistance, mechanic);
        foreach (int t; 1 .. cast(int) creatureTypes)
        {
            m.versus[t] = auras.multiplier(AuraType.modDamageDoneVersus, (int mask) => (mask & (1 << (t - 1))) != 0);
            m.critVersus[t] = auras.totalByMiscMask(AuraType.modCritPercentVersus, 1 << (t - 1));
        }
        return m;
    }

    /// Into a `Fighter` for the melee formulas.
    void into(ref Fighter f) const pure nothrow @nogc @safe
    {
        f.damageDone = swing;
        f.damageVersus = versus;
        f.critVersus = critVersus;
        f.damageTaken = taken;
        f.damageTakenFlat = takenFlat;
        f.mechanicResist = mechanicResist;
    }
}

/**
 * What a unit cannot be touched by (CMaNGOS's `IsImmuneToSpell`, `IsImmuneToSpellEffect`, `IsImmuneToDamage`): a
 * creature's template (`MechanicImmuneMask`, `SchoolImmuneMask`: a boss and stuns) and its auras (Divine Shield
 * and Ice Block a school immunity, Blessing of Freedom and Berserker Rage a mechanic's).
 */
struct Immunities
{
    uint schools;   /// school mask: no spell of these schools, no blow (`SCHOOL_IMMUNITY`)
    uint damage;    /// school mask: no damage of these schools (`DAMAGE_IMMUNITY`)
    uint mechanics; /// bit `mechanic - 1` (`MECHANIC_IMMUNITY`, `_MASK`)
    uint dispels;   /// bit `dispel type` (`DISPEL_IMMUNITY`): Faerie Fire's victims and the like
    ulong[3] effects; /// bit `effect` (`EFFECT_IMMUNITY`)
    ulong[4] states;  /// bit `aura type` (`STATE_IMMUNITY`)

    /// From a creature's template masks (0 for a player) and `auras`.
    static Immunities of(A)(const ref A auras, uint mechanicMask = 0, uint schoolMask = 0)
    {
        import dmangos.world.spellids : AuraType;

        Immunities m;
        m.mechanics = mechanicMask;
        m.schools = schoolMask;
        foreach (aura; auras.list)
            foreach (i; 0 .. 3)
            {
                if (!(aura.effects & (1 << i)))
                    continue;
                const misc = aura.misc(i);
                switch (aura.type(i))
                {
                case AuraType.schoolImmunity: m.schools |= misc; break;
                case AuraType.damageImmunity: m.damage |= misc; break;
                case AuraType.mechanicImmunity:
                    if (misc > 0 && misc <= 32)
                        m.mechanics |= 1u << (misc - 1);
                    break;
                case AuraType.mechanicImmunityMask: m.mechanics |= misc; break;
                case AuraType.dispelImmunity:
                    if (misc >= 0 && misc < 32)
                        m.dispels |= 1u << misc;
                    break;
                case AuraType.effectImmunity:
                    if (misc >= 0 && misc < 192)
                        m.effects[misc / 64] |= 1UL << (misc % 64);
                    break;
                case AuraType.stateImmunity:
                    if (misc >= 0 && misc < 256)
                        m.states[misc / 64] |= 1UL << (misc % 64);
                    break;
                default:
                    break;
                }
            }
        return m;
    }

    /// Whether it has any.
    bool any() const pure nothrow @nogc @safe
    {
        return schools || damage || mechanics || dispels || effects != effects.init || states != states.init;
    }

    /// Whether `mechanic` (1 ..) cannot touch it.
    bool toMechanic(uint mechanic) const pure nothrow @nogc @safe
    {
        return mechanic > 0 && mechanic <= 32 && (mechanics & (1u << (mechanic - 1))) != 0;
    }

    /// Whether a hostile spell (`school` an index, its `dispel` type and `mechanic`) cannot touch it at all.
    bool toSpell(uint school, uint dispel, uint mechanic) const pure nothrow @nogc @safe
    {
        return (school < 7 && (schools & (1u << school))) || (dispel < 32 && dispel && (dispels & (1u << dispel)))
            || toMechanic(mechanic);
    }

    /// Whether one effect (`effect`, its `mechanic`, the aura type it applies) cannot touch it.
    bool toEffect(uint effect, uint mechanic, uint auraType) const pure nothrow @nogc @safe
    {
        return (effect < 192 && (effects[effect / 64] & (1UL << (effect % 64)))) || toMechanic(mechanic)
            || (auraType && auraType < 256 && (states[auraType / 64] & (1UL << (auraType % 64))));
    }

    /// Whether damage of `school` (an index) cannot hurt it.
    bool toDamage(uint school) const pure nothrow @nogc @safe
    {
        return school < 7 && ((schools | damage) & (1u << school)) != 0;
    }
}

unittest
{
    Immunities boss;
    boss.mechanics = 1u << (12 - 1); // MECHANIC_STUN
    assert(boss.toMechanic(12) && !boss.toMechanic(5));
    assert(boss.toEffect(6, 12, 12) && !boss.toEffect(2, 0, 0), "a stun effect, not the damage beside it");
    Immunities shielded;
    shielded.schools = 0x7F; // Divine Shield: every school
    assert(shielded.toSpell(4, 0, 0) && shielded.toDamage(0));
}

/// The spell mechanics (`Mechanics`) `Fighter.mechanicResist` covers.
enum size_t mechanics = 32;

/// Creature types (`CreatureType`), as the tables by type in `Fighter` index them: 1 beast to 10 not specified.
enum size_t creatureTypes = 12;
/// ditto: a humanoid, as players are.
enum uint creatureTypeHumanoid = 7;

/// What `type` of a victim of `creatureType` takes from the attacker's auras and its own (by the blow's school).
float damageFactor(const Fighter attacker, const Fighter victim, AttackType type, uint school)
    pure nothrow @nogc @safe
{
    const versus = victim.creatureType < creatureTypes ? attacker.damageVersus[victim.creatureType] : 1;
    return attacker.damageDone[type] * versus * (school < 7 ? victim.damageTaken[school] : 1);
}

// ---------------------------------------------------------------------------
// Levels and skills
// ---------------------------------------------------------------------------

/// Its level against `target`: a world boss counts as above its target.
uint levelFor(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    if (!self.worldBoss)
        return self.level;
    const level = target.level + worldBossLevelDiff;
    return level > 255 ? 255 : level;
}

/// The most skill its level against `target` allows: five a level.
uint skillMaxForLevel(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    return levelFor(self, target) * 5;
}

/// The most skill its level allows, without a target.
uint skillMaxForLevel(const Fighter self) pure nothrow @nogc @safe
{
    return self.level * 5;
}

/// Its weapon skill: against players a player uses the higher of its skill and maximum.
uint weaponSkillValue(const Fighter self, AttackType type, const Fighter target) pure nothrow @nogc @safe
{
    if (!self.player)
        return levelFor(self, target) * 5; // a creature's: five a level
    const value = self.weaponSkill[type];
    return target.player && self.weaponSkillMax[type] > value ? self.weaponSkillMax[type] : value;
}

/// Its defense skill: a creature's five a level; against players a player uses the higher of its skill and maximum.
uint defenseSkillValue(const Fighter self, const Fighter attacker) pure nothrow @nogc @safe
{
    if (!self.player)
        return levelFor(self, attacker) * 5;
    return attacker.player && self.defenseSkillMax > self.defenseSkill ? self.defenseSkillMax : self.defenseSkill;
}

// ---------------------------------------------------------------------------
// Where they stand
// ---------------------------------------------------------------------------

/// Whether `target` is within `arc` radians of where `self` faces.
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

/// Each in front of the other.
bool isFacingFront(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    return hasInArc(target.position, self.position) && hasInArc(self.position, target.position);
}

/// Facing the target, which faces away.
bool isFacingBack(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    return !hasInArc(target.position, self.position) && hasInArc(self.position, target.position);
}

/// The melee reach of the two: both reaches and the offset, at least `attackDistance`.
float meleeReach(const Fighter self, const Fighter target) pure nothrow @nogc @safe
{
    const reach = self.combatReach + target.combatReach + baseMeleeRangeOffset;
    return reach < attackDistance ? attackDistance : reach;
}

/// Whether `self` reaches `target` in melee: players measure in three dimensions, creatures on the ground.
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

/// The chance to miss: 5%, more for dual wielding and better defense, less for skill.
float missChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    float chance = 5; // totems aside, everyone is missed 5% of the time
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
    chance -= attacker.hitBonus;
    chance -= victim.attackerHit[type == AttackType.ranged ? 1 : 0]; // Heightened Senses: less often hit
    const minimum = difference > 10 ? 1.0f : 0.0f;
    return chance < minimum ? minimum : chance > 100 ? 100 : chance;
}

/// The chance the victim dodges.
float dodgeChance(const Fighter victim, const Fighter attacker, AttackType type) pure nothrow @nogc @safe
{
    float chance = victim.dodge;
    if (chance < 0.005f)
        return 0;
    const difference = int(defenseSkillValue(victim, attacker)) - int(weaponSkillValue(attacker, type, victim));
    const factor = !victim.playerControlled && difference > 0 ? 0.1f : 0.04f;
    return clamp100(chance + difference * factor);
}

/// The chance the victim parries.
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

/// The chance the victim blocks.
float blockChance(const Fighter victim, const Fighter attacker, AttackType type) pure nothrow @nogc @safe
{
    float chance = victim.block;
    if (chance < 0.005f)
        return 0;
    const difference = int(defenseSkillValue(victim, attacker)) - int(weaponSkillValue(attacker, type, victim));
    const factor = !victim.playerControlled && difference > 0 ? 0.0f : 0.04f;
    return clamp100(chance + difference * factor);
}

/// The chance of a crushing blow: 15% and 2% a point when the weapon beats the capped defense by 15.
float crushChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    const cap = skillMaxForLevel(victim);
    auto defense = defenseSkillValue(victim, attacker);
    if (defense > cap)
        defense = cap;
    const deficit = int(weaponSkillValue(attacker, type, victim)) - int(defense);
    return deficit >= 15 ? clamp100(2 * deficit - 15) : 0;
}

/// The chance of a glancing blow: from 10% up with the victim's defense over the capped skill.
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

/// The chance of a critical hit: against creatures, 1% less for each level above the attacker.
float critChance(const Fighter attacker, const Fighter victim, AttackType type) pure nothrow @nogc @safe
{
    float chance = attacker.crit;
    if (chance < 0.005f)
        return 0;
    const vsPlayer = victim.playerControlled;
    const skill = !vsPlayer ? weaponSkillValue(attacker, type, victim) : skillMaxForLevel(attacker, victim);
    const difference = int(skill) - int(defenseSkillValue(victim, attacker));
    chance += difference * (vsPlayer ? 0.04f : 0.2f);
    chance += victim.attackerCrit[type == AttackType.ranged ? 1 : 0]; // Sleight of Hand: crit less often
    return clamp100(chance);
}

/// The classes that use wands: priests, mages and warlocks.
private bool isWandUser(ubyte classId) pure nothrow @nogc @safe
{
    return classId == 5 || classId == 8 || classId == 9;
}

/// Whether the victim may dodge: a player dodges only what comes from the front.
bool canDodge(const Fighter victim, const Fighter attacker) pure nothrow @nogc @safe
{
    if (!victim.canDodge || victim.dodge < 0.005f)
        return false;
    return !victim.player || isFacingFront(attacker, victim);
}

/**
 * Parry haste: a parry brings the parrier's next swing nearer (CMaNGOS's `Unit::DealMeleeDamage`). A swing more
 * than 60% of the weapon's time away comes 40% of it sooner; one between 20% and 60% away comes at 20%; one
 * nearer stays.
 */
uint parryHasted(uint timer, uint attackTime) pure nothrow @nogc @safe
{
    const p20 = attackTime * 0.2f, p60 = 3 * p20;
    if (timer > p60)
        return cast(uint) (timer - 2 * p20);
    if (timer > p20)
        return cast(uint) p20;
    return timer;
}

unittest
{
    assert(parryHasted(2000, 2000) == 1200); // just swung: 40% sooner
    assert(parryHasted(1000, 2000) == 400);  // half way: to 20%
    assert(parryHasted(300, 2000) == 300);   // nearly ready: as it is
    assert(parryHasted(0, 2000) == 0);
}

/// Whether the victim may parry: only from the front.
bool canParry(const Fighter victim, const Fighter attacker) pure nothrow @nogc @safe
{
    return victim.canParry && victim.parry >= 0.005f && isFacingFront(attacker, victim);
}

/// Whether the victim may block: physical attacks from the front.
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
 * The attack table: one roll (`random`, 1 to 10000) through miss, dodge,
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
        chance[5] = hundredths(critChance(attacker, victim, type)
            + (victim.creatureType < creatureTypes ? attacker.critVersus[victim.creatureType] : 0));
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

/// One swing worked out.
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
    uint absorbed;             /// what the victim's shields took (`damage` is after it)
}

/// Damage after armor: armor takes up to 75%, less against higher levels.
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

/// A weapon's damage: a whole number between its minimum and maximum (5 if it has none).
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

/// A glancing blow does 1% to 99% of the damage, less the better the defense.
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
 * One swing: the weapon's damage less armor (for physical attacks), then the attack
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

    // A victim its school cannot hurt (Divine Shield, a boss immune to physical): "Immune", no roll.
    if (victim.immune.toDamage(d.school))
    {
        d.outcome = MeleeHitOutcome.normal;
        d.targetState = VictimState.isImmune;
        d.damage = d.cleanDamage = 0;
        return d;
    }
    float damage = weaponDamage(attacker, type, rng) * damageFactor(attacker, victim, type, d.school);
    if (type == AttackType.ranged && victim.rangedTakenFlat)
        damage = imported!"std.algorithm.comparison".max(0.0f, damage + victim.rangedTakenFlat);
    if (d.school < 7 && victim.damageTakenFlat[d.school]) // the victim's flat part, as its percent takes it
        damage = imported!"std.algorithm.comparison".max(0.0f, damage + victim.damageTakenFlat[d.school] * victim.damageTaken[d.school]);
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
        d.damage *= 2; // a critical attack does double
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

/// Rage (in tenths, as the power field holds it) for melee damage dealt or taken.
uint rageReward(uint level, uint damage, bool dealt) pure nothrow @nogc @safe
{
    const conversion = cast(float)(0.0091107836 * level * level + 3.225598133 * level) + 4.2652911f;
    const rage = damage / conversion * (dealt ? 7.5f : 2.5f);
    return cast(uint)(rage * 10);
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------

/// `SMSG_ATTACKERSTATEUPDATE`: one damage line, no debug block.
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
    w.put(d.absorbed);
    w.put(int(0));  // resisted
    w.put(cast(uint) d.targetState);
    w.put(uint(0));
    w.put(uint(0)); // spell id
    w.put(d.blocked);
    return w.data;
}

/// `SMSG_ATTACKSTART`: `attacker` starts swinging at `victim`.
const(ubyte)[] attackStart(ulong attacker, ulong victim)
{
    ByteWriter w;
    w.put(attacker);
    w.put(victim);
    return w.data;
}

/// `SMSG_ATTACKSTOP`: `victim` 0 for none; `dead` says the attacker died.
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
    wolf.evading = false;
    wolf.immune.schools = 1; // physical: Divine Shield's kind
    const immune = calculateMeleeDamage(player, wolf, AttackType.mainHand, rng);
    assert(immune.targetState == VictimState.isImmune && immune.damage == 0);
    wolf.immune.schools = 0;
    // Sleight of Hand on the victim: crits against it less often.
    const before = critChance(player, wolf, AttackType.mainHand);
    wolf.attackerCrit[0] = -2;
    assert(critChance(player, wolf, AttackType.mainHand) < before || before == 0);
    wolf.attackerCrit[0] = 0;

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

/**
 * The partial resist distribution, precalculated: for each
 * whole percent of effective resistance 0 .. 100, the chances (in hundredths of a percent) of 0%,
 * 25%, 50%, 75% and 100% of a spell's damage resisted; percents between are interpolated.
 */
immutable uint[5][101] partialResistRows = [
    [10000, 0, 0, 0, 0], [9700, 200, 100, 0, 0], [9400, 400, 200, 0, 0], [9000, 800, 200, 0, 0],
    [8700, 1000, 300, 0, 0], [8400, 1200, 400, 0, 0], [8200, 1300, 400, 100, 0], [7900, 1500, 500, 100, 0],
    [7600, 1700, 600, 100, 0], [7300, 1900, 700, 100, 0], [6900, 2300, 700, 100, 0], [6600, 2500, 800, 100, 0],
    [6300, 2700, 900, 100, 0], [6000, 2900, 1000, 100, 0], [5800, 3000, 1000, 200, 0], [5400, 3300, 1100, 200, 0],
    [5100, 3600, 1100, 200, 0], [4800, 3800, 1200, 200, 0], [4400, 4200, 1200, 200, 0], [4100, 4400, 1300, 200, 0],
    [3700, 4800, 1300, 200, 0], [3400, 5000, 1400, 200, 0], [3100, 5200, 1500, 200, 0], [3000, 5200, 1500, 200, 100],
    [2800, 5300, 1500, 300, 100], [2500, 5500, 1600, 300, 100], [2400, 5400, 1700, 400, 100], [2300, 5300, 1800, 500, 100],
    [2200, 5100, 2100, 500, 100], [2100, 5000, 2200, 600, 100], [2000, 4900, 2400, 600, 100], [1900, 4700, 2600, 700, 100],
    [1800, 4600, 2700, 800, 100], [1700, 4400, 3000, 800, 100], [1600, 4300, 3100, 900, 100], [1500, 4200, 3200, 1000, 100],
    [1400, 4100, 3300, 1100, 100], [1300, 3900, 3600, 1100, 100], [1300, 3600, 3800, 1200, 100], [1200, 3500, 3900, 1300, 100],
    [1100, 3400, 4000, 1400, 100], [1000, 3300, 4100, 1500, 100], [900, 3100, 4400, 1500, 100], [800, 3000, 4500, 1600, 100],
    [800, 2700, 4700, 1700, 100], [700, 2600, 4800, 1800, 100], [600, 2500, 4900, 1900, 100], [600, 2300, 5000, 1900, 200],
    [500, 2200, 5100, 2000, 200], [300, 2200, 5300, 2000, 200], [200, 2100, 5400, 2100, 200], [200, 2000, 5300, 2200, 300],
    [200, 2000, 5100, 2200, 500], [200, 1900, 5000, 2300, 600], [100, 1900, 4900, 2500, 600], [100, 1800, 4800, 2600, 700],
    [100, 1700, 4700, 2700, 800], [100, 1600, 4500, 3000, 800], [100, 1500, 4400, 3100, 900], [100, 1500, 4100, 3300, 1000],
    [100, 1400, 4000, 3400, 1100], [100, 1300, 3900, 3500, 1200], [100, 1200, 3800, 3600, 1300], [100, 1100, 3600, 3900, 1300],
    [100, 1100, 3300, 4100, 1400], [100, 1000, 3200, 4200, 1500], [100, 900, 3100, 4300, 1600], [100, 800, 3000, 4400, 1700],
    [100, 800, 2700, 4600, 1800], [100, 700, 2600, 4700, 1900], [100, 600, 2400, 4900, 2000], [100, 600, 2200, 5000, 2100],
    [100, 500, 2100, 5100, 2200], [100, 500, 1800, 5300, 2300], [100, 400, 1700, 5400, 2400], [100, 300, 1600, 5500, 2500],
    [100, 300, 1500, 5300, 2800], [100, 200, 1500, 5200, 3000], [0, 200, 1500, 5200, 3100], [0, 200, 1400, 5000, 3400],
    [0, 200, 1300, 4800, 3700], [0, 200, 1300, 4400, 4100], [0, 200, 1200, 4200, 4400], [0, 200, 1200, 3800, 4800],
    [0, 200, 1100, 3600, 5100], [0, 200, 1100, 3300, 5400], [0, 200, 1000, 3000, 5800], [0, 100, 1000, 2900, 6000],
    [0, 100, 900, 2700, 6300], [0, 100, 800, 2500, 6600], [0, 100, 700, 2300, 6900], [0, 100, 700, 1900, 7300],
    [0, 100, 600, 1700, 7600], [0, 100, 500, 1500, 7900], [0, 100, 400, 1300, 8200], [0, 0, 400, 1200, 8400],
    [0, 0, 300, 1000, 8700], [0, 0, 200, 800, 9000], [0, 0, 200, 400, 9400], [0, 0, 100, 200, 9700],
    [0, 0, 0, 0, 10000],
];

/**
 * The effective resistance (percent) of a creature hit by a player's spell of `school`
 * (not physical, not holy): `resistance` against 5 per attacker level (100 at least), times 0.75,
 * plus 0.4 per point of the victim's level skill above the attacker's; at most 75.
 */
float effectiveResistPercent(int resistance, uint attackerLevel, uint victimLevel, bool victimCreature)
    pure nothrow @nogc @safe
{
    import std.algorithm.comparison : max, min;

    if (resistance < 0)
    {
        const skill = max(victimLevel * 5.0f, 100.0f);
        return resistance / skill * 100;
    }
    const skill = max(attackerLevel * 5.0f, 100.0f);
    float percent = resistance / skill * 100 * 0.75f;
    if (victimCreature)
        percent += 0.4f * max(victimLevel * 5.0f - skill, 0.0f);
    return min(percent, 75.0f);
}

/**
 * The chance (percent) a magic spell is resisted whole by a victim with `resistance` of its school: a
 * binary spell by the whole effective resistance, another only as often as the partial-resist table
 * resists all of it.
 */
float fullResistChance(int resistance, uint attackerLevel, uint victimLevel, bool binary, bool victimCreature)
    pure nothrow @nogc @safe
{
    const percent = effectiveResistPercent(resistance, attackerLevel, victimLevel, victimCreature);
    if (!(percent > 0))
        return 0;
    return binary ? percent : partialResistRows[cast(uint) percent][4] * 0.01f;
}

unittest
{
    // 150 fire resistance against a level 60 caster: 37.5%; a binary spell is resisted that often, another
    // whole only as the table's last column says.
    assert(fullResistChance(150, 60, 60, true, false) == 37.5f);
    assert(fullResistChance(150, 60, 60, false, false) == partialResistRows[37][4] * 0.01f);
    assert(fullResistChance(0, 60, 60, true, false) == 0);
}

/**
 * A partial resist roll: the share of the damage resisted (0, 0.25, 0.5
 * or 0.75; never all, which was the hit roll's), from `percent` and a `roll` of 1 .. 10000. Negative
 * percents are vulnerability: a negative share. A direct hit with more than 54% never goes whole.
 */
float rollPartialResist(float percent, uint roll, bool direct = true) pure nothrow @nogc @safe
{
    import std.math : round;

    if (percent < 0)
        return percent * 0.01f;
    const index = cast(uint)(percent * 100);
    if (index == 0)
        return 0;
    const row = index / 100, step = index % 100;
    uint[5] chances;
    foreach (c; 0 .. 5)
    {
        const base = partialResistRows[row][c];
        const ahead = row + 1 < partialResistRows.length ? partialResistRows[row + 1][c] : base;
        const value = base + round((cast(double) ahead - base) * (step / 100.0));
        chances[c] = value < 0 ? 0 : cast(uint) value;
    }
    uint portion = 4;
    uint sum;
    foreach (ubyte c; 0 .. 5)
    {
        sum += chances[c];
        if (roll <= sum)
        {
            portion = c;
            break;
        }
    }
    if (portion > 3)
        portion = 3;
    if (portion == 0 && percent > 54.0f && direct)
        ++portion;
    return portion / 4.0f;
}

unittest
{
    assert(effectiveResistPercent(0, 60, 60, true) == 0 && rollPartialResist(0, 1) == 0);
    // 300 fire resistance against a level 60 caster: 300/300*100*0.75 = 75% (the cap).
    assert(effectiveResistPercent(300, 60, 60, true) == 75);
    assert(rollPartialResist(75, 10000) == 0.75f && rollPartialResist(75, 5000) == 0.75f, "at 75%: mostly three quarters");
    assert(rollPartialResist(75, 1) == 0.25f, "never whole above 54%");
    // A level 63 boss against level 60: 15 skill above, 6% more.
    assert(effectiveResistPercent(0, 60, 63, true) == 6);
    assert(rollPartialResist(10, 1) == 0 && rollPartialResist(10, 10000) > 0);
    assert(effectiveResistPercent(-50, 60, 60, true) < 0 && rollPartialResist(-10, 1) < 0);
}

// Hit auras make misses rarer.
unittest
{
    Fighter player, wolf;
    player.player = player.playerControlled = true;
    player.level = wolf.level = 10;
    player.weaponSkill[0] = player.weaponSkillMax[0] = 50;
    wolf.defenseSkill = wolf.defenseSkillMax = 50;
    const plain = missChance(player, wolf, AttackType.mainHand);
    player.hitBonus = 3;
    assert(missChance(player, wolf, AttackType.mainHand) == plain - 3);
}

/// What a partial resist left of a spell's damage, and what it took.
struct Resisted
{
    uint damage;   /// what lands
    uint resisted; /// what was resisted (shown in the damage log)
}

/**
 * A spell's `damage` against `victim`, after the partial resist of its `resistance` to the spell's school,
 * for every caster kind and victim kind alike. `roll` is a number from 1 to 10000.
 *
 * The level bonus of `effectiveResistPercent` counts for a creature victim of a spell that is not binary.
 * A binary spell's direct damage is not resisted in part (it was resisted whole, or not at all, by the hit
 * roll); its ticks are, at a tenth of the resistance. A negative resistance adds to the damage.
 */
Resisted partiallyResisted(uint damage, int resistance, uint casterLevel, const Fighter victim, bool binary,
    bool direct, uint roll) pure nothrow @nogc @safe
{
    if (binary && direct)
        return Resisted(damage, 0);
    float percent = effectiveResistPercent(resistance, casterLevel, victim.level, !victim.player && !binary);
    if (binary && percent > 0)
        percent *= 0.1f;
    const share = rollPartialResist(percent, roll, direct);
    if (share > 0)
    {
        const taken = cast(uint)(damage * share);
        return Resisted(damage - taken, taken);
    }
    if (share < 0)
        return Resisted(damage + cast(uint)(damage * -share), 0);
    return Resisted(damage, 0);
}

pure nothrow @nogc @safe unittest
{
    Fighter wolf, player;
    wolf.level = 60;
    player.level = 60;
    player.player = true;
    assert(partiallyResisted(100, 0, 60, wolf, false, true, 5000) == Resisted(100, 0), "no resistance: all lands");
    assert(partiallyResisted(100, 300, 60, wolf, true, true, 1) == Resisted(100, 0), "binary direct: never in part");
    const half = partiallyResisted(100, 300, 60, player, false, true, 10000);
    assert(half.damage + half.resisted == 100 && half.resisted > 0, "75% effective: a share resisted");
    // The level bonus is the creature's only: a level-63 creature resists more than a level-63 player.
    Fighter boss = wolf, champion = player;
    boss.level = champion.level = 63;
    assert(effectiveResistPercent(100, 60, 63, true) > effectiveResistPercent(100, 60, 63, false));
}

pure nothrow @nogc @safe unittest
{
    Fighter weak;
    weak.level = 10;
    const more = partiallyResisted(100, -50, 60, weak, false, true, 5000);
    assert(more.damage >= 100 && more.resisted == 0, "a negative resistance adds");
}

// Auras on both sides of a swing: the attacker's damage done (by attack type) and against a creature type, the
// victim's damage taken (by school); and crit against a type in the attack table.
unittest
{
    import std.math : isClose;

    Fighter attacker, victim;
    attacker.damageDone[AttackType.mainHand] = 1.1f;   // Two-Handed Weapon Specialization
    attacker.damageVersus[2] = 1.05f;                  // Monster Slaying: dragonkin
    victim.creatureType = 2;
    victim.damageTaken[0] = 0.9f;                      // Defensive Stance
    assert(isClose(damageFactor(attacker, victim, AttackType.mainHand, 0), 1.1f * 1.05f * 0.9f));
    assert(isClose(damageFactor(attacker, victim, AttackType.offHand, 3), 1.05f), "fire: not taken less; off hand");
    victim.creatureType = 7;
    assert(isClose(damageFactor(attacker, victim, AttackType.mainHand, 0), 1.1f * 0.9f), "not dragonkin");

    // 3% more crit against beasts moves the crit band.
    attacker.player = attacker.playerControlled = true;
    attacker.level = victim.level = 10;
    attacker.weaponSkill[0] = attacker.weaponSkillMax[0] = 50;
    victim.defenseSkill = victim.defenseSkillMax = 50;
    attacker.crit = 5;
    victim.canDodge = false;
    victim.creatureType = 1;
    const plain = rollMeleeOutcome(attacker, victim, AttackType.mainHand, 1100); // past 5% miss and 5% crit
    attacker.critVersus[1] = 3;
    const withTalent = rollMeleeOutcome(attacker, victim, AttackType.mainHand, 1100);
    assert(plain == MeleeHitOutcome.normal && withTalent == MeleeHitOutcome.crit, "8% crit now: the 11th percent is one");
}

// Stealth (CMaNGOS's numbers): a level 60 monster sees Stealth rank 4 (300) at 7.5 yards, in front only; an alert
// reaches further; detection auras and the detector's level widen it.
unittest
{
    import std.math : isClose;

    Fighter monster, rogue;
    monster.level = rogue.level = 60;
    rogue.player = rogue.playerControlled = true;
    rogue.stealthed = true;
    rogue.stealth = 300;
    assert(isClose(stealthDetectRange(monster, rogue), (30 + 59 * 5 - 300) * 0.3f));
    assert(isClose(stealthDetectRange(monster, rogue, true), 7.5f + 7.5f * 0.08f + 1.5f));
    monster.stealthDetect = 50; // a detection aura
    assert(isClose(stealthDetectRange(monster, rogue), 22.5f));
    monster.stealthDetect = 0;
    rogue.stealth = 1000;
    assert(stealthDetectRange(monster, rogue) == rogue.combatReach, "never nearer than its reach");

    rogue.stealth = 300;
    monster.position = Position(0, 0, 0, 0); // facing +x
    rogue.position = Position(5, 0, 0);
    assert(detects(monster, rogue, 20), "5 yards in front");
    rogue.position = Position(-5, 0, 0);
    assert(!detects(monster, rogue, 20), "behind: never");
    rogue.position = Position(9, 0, 0);
    assert(!detects(monster, rogue, 20) && detects(monster, rogue, 20, true), "9 yards: not seen, but on its guard");
    rogue.stealthed = false;
    assert(detects(monster, rogue, 20), "not stealthed: seen");
}
