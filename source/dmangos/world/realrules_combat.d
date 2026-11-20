/**
 * The combat rules (docs/FORMULAS.md, "The melee attack table", "Spell resistance", "Procs", "Diminishing
 * returns") on the real data: characters, creatures, spells and Blizzard's proc data as the world database, the
 * client's DBC files and data/procs.csv have them. Each test names the sourced number and what the rule before gave.
 * They run only with `DMANGOS_REAL_DATA` (`dmangos.world.realspelltests`); the proc tests only with data/procs.csv
 * (tools/fetch-procs.py).
 */
module dmangos.world.realrules_combat;

version (unittest):

import core.time : msecs, seconds;
import std.format : format;
import std.math : abs, isClose, PI, sqrt;

import dmangos.world.character : Character;
import dmangos.world.combat;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.player : Player;
import dmangos.world.realspelltests : classMageId, classWarriorId, haveRealData, RealWorld;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient;
import dmangos.world.testdata : raceOrc;

/// `entry` spawned two yards east of `who`, facing it.
private Creature spawnNear(ref RealWorld w, ref TestClient who, uint entry)
{
    auto me = cast(Player) who.session.character;
    auto at = me.position;
    at.x += 2;
    at.orientation = PI;
    auto creature = w.context.summonCreature(w.context.map(0), entry, at, TempSpawnType.manual, 0, 0);
    assert(creature !is null, "no such creature in the world database");
    who.read();
    return creature;
}

/// The real spell `id`.
private const(SpellInfo)* spellOf(ref RealWorld w, uint id)
{
    const s = w.context.data.spells.spell(id);
    assert(s !is null, format!"no spell %s"(id));
    return s;
}

/// A level 60 warrior facing Grand Inquisitor Isillien (1840, level 63), both as the attack table sees them.
private void warriorAndBoss(ref RealWorld w, uint guid, out Fighter warrior, out Fighter boss)
{
    auto who = w.character(guid, format!"Tank%s"(guid), classWarriorId, 60, []);
    auto me = cast(Player) who.session.character;
    me.movement.position.orientation = 0; // east, at the boss
    auto rag = spawnNear(w, who, 1840);
    warrior = (cast(Character) who.session.inWorld).player.fighter;
    boss = rag.fighter;
    boss.evading = false;
    warrior.weaponSkill[0] = warrior.weaponSkillMax[0] = 300;
    warrior.dualWield = false;
    warrior.hitBonus = 0;
}

/**
 * Against a creature three levels above (Grand Inquisitor Isillien, level 63, to a level 60 at 300 skill), as Blizzard stated (quoted on Magey's
 * "Attack-table"): "Players have an 8% chance to miss", "a 14% Parry chance", 6.5% dodge; the hit cap 9% ("the first
 * 1% of +hit ... ignored"). The rule before gave 9% miss and 1% at least whatever the hit; and 6% parry at 305 skill
 * (by the weapon skill, where Classic Era measured 13.5%: by the skill at most five a level).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    Fighter warrior, boss;
    warriorAndBoss(w, 501, warrior, boss);
    assert(boss.level == 63);
    assert(isClose(missChance(warrior, boss, AttackType.mainHand), 8.0f), "Blizzard: 8%");
    assert(isClose(dodgeChance(boss, warrior, AttackType.mainHand), 6.5f), "Blizzard: 6.5%");
    assert(isClose(parryChance(boss, warrior, AttackType.mainHand), 14.0f), "Blizzard: 14%");
    warrior.hitBonus = 9;
    assert(missChance(warrior, boss, AttackType.mainHand) == 0, "9% hit: never missed (the rule before: 1%)");
    warrior.hitBonus = 8;
    assert(isClose(missChance(warrior, boss, AttackType.mainHand), 1.0f), "8% hit: the first 1% ignored");
    warrior.hitBonus = 0;
    warrior.weaponSkill[0] = warrior.weaponSkillMax[0] = 305; // Sword Specialization's kind
    assert(isClose(missChance(warrior, boss, AttackType.mainHand), 6.0f), "+5 skill: 6%");
    assert(isClose(parryChance(boss, warrior, AttackType.mainHand), 14.0f), "parry by the capped skill (before: 6%)");
    assert(isClose(dodgeChance(boss, warrior, AttackType.mainHand), 6.0f), "dodge by the skill: 6%");
}

/**
 * The same, measured: 200,000 swings of the level 60 warrior at the level 63 Isillien through `calculateMeleeDamage` miss 8%,
 * are dodged 6.5%, parried 14%, glance 40% (Magey's +3 measurements: 7.81%, 6.29%, 13.97%, 40.36%), each within five
 * standard deviations. The rule before missed 9% (36 deviations off).
 */
unittest
{
    if (!haveRealData())
        return;
    import std.random : Random;

    auto w = RealWorld.make();
    Fighter warrior, boss;
    warriorAndBoss(w, 502, warrior, boss);
    warrior.crit = 5;
    warrior.auraCrit = 0;
    auto rng = Random(20_261_120);
    enum n = 200_000;
    uint[MeleeHitOutcome.max + 1] seen;
    foreach (_; 0 .. n)
        ++seen[calculateMeleeDamage(warrior, boss, AttackType.mainHand, rng).outcome];
    void near(MeleeHitOutcome outcome, double percent)
    {
        const p = percent / 100, expected = n * p, sd = sqrt(n * p * (1 - p));
        assert(abs(seen[outcome] - expected) <= 5 * sd,
            format!"%s: %s of %s, not %s%%"(outcome, seen[outcome], n, percent));
    }
    near(MeleeHitOutcome.miss, 8);
    near(MeleeHitOutcome.dodge, 6.5);
    near(MeleeHitOutcome.parry, 14);
    near(MeleeHitOutcome.glancing, 40);
    near(MeleeHitOutcome.crit, 2); // 5% less 3% (0.2% a point of 15)
}

/**
 * Crit from auras three levels above: the real Songflower Serenade (15366, 5% crit) is aura crit, of which a level 63
 * takes 1.8% (Blizzard: "a single modifier placed on total Critical Strike gained from auras"; 1.8% measured, Magey's
 * "Crit-aura-suppression"). The rule before took only the 3% of the skill.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.auras : makeAura;
    import dmangos.world.spellcast : effectValue;

    auto w = RealWorld.make();
    auto who = w.character(503, "Serenaded", classWarriorId, 60, []);
    auto me = cast(Character) who.session.inWorld;
    const song = spellOf(w, 15366);
    int[3] values;
    foreach (i; 0 .. 3)
        values[i] = effectValue(*song, i, 60, 0);
    me.addAura(makeAura(song, me.player.guid, 60, 3_600_000, true, values));
    assert(me.player.auras.find(15366) !is null, "Songflower Serenade on");
    me.player.movement.position.orientation = 0;
    auto rag = spawnNear(w, who, 1840);
    auto warrior = me.player.fighter;
    assert(isClose(warrior.auraCrit, 5.0f), format!"Songflower Serenade: 5%% aura crit, not %s"(warrior.auraCrit));
    warrior.weaponSkill[0] = warrior.weaponSkillMax[0] = 300;
    const crit = critChance(warrior, rag.fighter, AttackType.mainHand);
    assert(isClose(crit, warrior.crit - 3 - 1.8f), format!"%s of %s"(crit, warrior.crit));
}

/**
 * A creature below level 10 is missed its level in tenths as often (Beaza's rule, measured by Magey): a level 1
 * warrior misses a level 1 Kobold Vermin 0.5% of the time. The rule before: 5%.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(504, "Novice", classWarriorId, 1, []);
    auto me = cast(Character) who.session.inWorld;
    me.player.movement.position.orientation = 0;
    auto kobold = spawnNear(w, who, 6);
    auto warrior = me.player.fighter, vermin = kobold.fighter;
    warrior.weaponSkill[0] = warrior.weaponSkillMax[0] = 5;
    vermin.level = 1;
    assert(isClose(missChance(warrior, vermin, AttackType.mainHand), 0.5f));
    vermin.level = 2; // 10 defense to 5 skill: 5.5% of two tenths
    assert(isClose(missChance(warrior, vermin, AttackType.mainHand), 1.1f));
}

/**
 * Ranged attacks are never dodged nor parried, but may be blocked: the 1.12 tooltips of Dodge (81, "a chance to
 * dodge enemy melee attacks"), Parry (3127, "enemy melee attacks") and Block (107, "enemy melee and ranged
 * attacks"). The rule before let a creature dodge an Auto Shot (and never a ranged ability).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    Fighter hunter, boss;
    warriorAndBoss(w, 505, hunter, boss);
    hunter.weaponSkill[AttackType.ranged] = hunter.weaponSkillMax[AttackType.ranged] = 300;
    foreach (roll; 1 .. 10_001)
    {
        const outcome = rollMeleeOutcome(hunter, boss, AttackType.ranged, roll);
        assert(outcome != MeleeHitOutcome.dodge && outcome != MeleeHitOutcome.parry, format!"roll %s"(roll));
    }
    assert(rollMeleeOutcome(hunter, boss, AttackType.ranged, 801) != MeleeHitOutcome.dodge,
        "past the 8% miss: before, a dodge");
}
