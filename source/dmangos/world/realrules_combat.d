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

/**
 * Binary or resisted in part, by Blizzard's rule ("Against direct-damage spells (... such as Fireball, Mind Blast,
 * and Earth Shock), this resistance is the percentage of damage you will resist on average"; the rest resisted whole
 * or not at all): Earth Shock (8042: damage and an interrupt) in part, which the rule before made binary; Fireball
 * (133) in part; Corruption (172) and Frost Nova (122: a root on its damage) and Frostbolt (116: a slow) binary.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.spellcast : isBinarySpell;

    auto w = RealWorld.make();
    assert(!isBinarySpell(*spellOf(w, 8042)), "Earth Shock: Blizzard's example of a spell resisted in part");
    assert(!isBinarySpell(*spellOf(w, 133)), "Fireball");
    assert(isBinarySpell(*spellOf(w, 172)), "Corruption");
    assert(isBinarySpell(*spellOf(w, 122)), "Frost Nova");
    assert(isBinarySpell(*spellOf(w, 116)), "Frostbolt");
}

/**
 * Resisted in part: at the 75% cap a direct-damage spell still lands whole 1% of the time in Blizzard's table, 1.3%
 * of the casts not resisted whole (the rule before: never above 54%); a binary spell's ticks (Corruption on a level
 * 60 with 300 shadow resistance) are never resisted in part ("the straight % chance to completely resist the spell":
 * the rule before resisted them at a tenth of the resistance).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    uint whole;
    foreach (roll; 1 .. 10_001)
        whole += rollPartialResist(75, roll) == 0;
    assert(abs(whole - 133.0) <= 2, format!"%s of 10000 whole at 75%%"(whole));
    auto who = w.character(506, "Warded", classWarriorId, 60, []);
    auto victim = (cast(Character) who.session.inWorld).player.fighter;
    const corruption = spellOf(w, 172);
    import dmangos.world.spellcast : isBinarySpell;

    foreach (roll; 1 .. 10_001)
        assert(partiallyResisted(100, 300, 60, victim, isBinarySpell(*corruption), roll) == Resisted(100, 0));
}

/**
 * Classic Era's `ProcTypeMask_0` against the 1.12 Spell.dbc's `ProcFlags`, on the real data: bits 0 to 20 are the same
 * events. Every aura of `spell_proc_event` Classic Era has as 1.12 has it matches on them; most auras of all have the
 * same mask. Nightfall's and Pyroclasm's bit 21 and Vampiric Embrace's and Illusion's 0x80000000 are later events,
 * which the mapping drops.
 */
unittest
{
    if (!haveRealData() || haveProcData() == false)
        return;
    import dmangos.world.procs : procFlagsOf;

    auto w = RealWorld.make();
    const procs = w.context.client.procOptions;
    uint same, either;
    foreach (id, ref o; procs)
        if (const s = w.context.data.spells.spell(id))
            if (s.casting.procFlags || o.typeMask)
            {
                ++either;
                same += procFlagsOf(o.typeMask) == s.casting.procFlags;
            }
    assert(same >= 950 && same * 10 >= either * 8, format!"%s of %s the same"(same, either));
    // Known auras of each kind of event: struck (Lightning Shield, Blood Craze), a swing (Flurry, Seal of Command), a
    // spell (Ignite, Arcane Concentration), ticks dealt (Nightfall, Pyroclasm) and taken (Vampiric Embrace), a kill
    // (Spinal Reaper).
    foreach (id; [324u, 10432, 16487, 12966, 20375, 11119, 11213, 18094, 18096, 15286, 21185])
    {
        const o = id in procs;
        assert(o !is null, format!"%s: no proc data"(id));
        assert(procFlagsOf(o.typeMask) == spellOf(w, id).casting.procFlags,
            format!"%s: %#x against 1.12's %#x"(id, o.typeMask, spellOf(w, id).casting.procFlags));
    }
    assert(procs[18094].typeMask != spellOf(w, 18094).casting.procFlags, "Nightfall: a later bit beside");
    assert(procs[15286].typeMask != spellOf(w, 15286).casting.procFlags, "Vampiric Embrace: a later bit beside");
}

/// Whether data/procs.csv was there (`ClientData.procOptions`).
private bool haveProcData()
{
    auto w = RealWorld.make();
    return w.context.client.procOptions.length != 0;
}

/**
 * Proc cooldowns from Blizzard's data (SpellAuraOptions.ProcCategoryRecovery) where Classic Era has the aura as 1.12
 * has it, else `spell_proc_event`'s: Lightning Shield 3.5 s (the world database's 3), Seal of Command 1 s (3),
 * Unbridled Wrath and Mace Specialization none (3), Sword Specialization 0.2 s (none), Setup 1 s (none); Omen of
 * Clarity, which Classic Era made proc from spells too, keeps the world database's 3 s.
 */
unittest
{
    if (!haveRealData() || !haveProcData())
        return;
    import dmangos.world.procs : procRule;

    auto w = RealWorld.make();
    uint cooldown(uint id, bool blizzard = true)
    {
        const rule = procRule(spellOf(w, id), w.context.data.spells.procEvent(id), w.context.client.procOptions);
        assert(rule.blizzardCooldown == blizzard, format!"%s: Blizzard's %s"(id, rule.blizzardCooldown));
        return rule.cooldown;
    }
    assert(cooldown(324) == 3500 && cooldown(10432) == 3500, "Lightning Shield");
    assert(cooldown(20375) == 1000, "Seal of Command");
    assert(cooldown(12322) == 0 && cooldown(13002) == 0, "Unbridled Wrath");
    assert(cooldown(12284) == 0 && cooldown(12704) == 0, "Mace Specialization");
    assert(cooldown(12281) == 200, "Sword Specialization");
    assert(cooldown(13983) == 1000, "Setup");
    assert(cooldown(16864, false) == 3000, "Omen of Clarity: not the aura 1.12 has");
}

/**
 * Lightning Shield (324) fires once in 3.5 s: struck again 3.2 s after a ball fired, the shaman keeps its next one
 * (the world database's 3 s let it fire).
 */
unittest
{
    if (!haveRealData() || !haveProcData())
        return;
    import dmangos.world.aurahandlers : ProcFlag;
    import dmangos.world.procs : ProcEx, ProcHit;

    auto w = RealWorld.make();
    auto who = w.character(507, "Thrall", 7, 60, [324], raceOrc);
    auto me = cast(Character) who.session.inWorld;
    me.player.movement.position.orientation = 0;
    const kobold = w.enemy(who);
    assert(w.cast_(who, 324) == imported!"dmangos.world.spellcast".SpellCastResult.ok);
    auto shield = me.player.auras.find(324);
    assert(shield !is null && shield.charges == 3);
    auto attacker = w.context.map(0).unit(kobold);
    const swing = ProcHit(null, ProcEx.normalHit, 5);
    me.runProcs(ProcFlag.takeMeleeSwing, attacker, swing);
    assert(shield.charges == 2, "a ball fired");
    w.now += 3200.msecs;
    me.runProcs(ProcFlag.takeMeleeSwing, attacker, swing);
    assert(shield.charges == 2, "3.2 s on: none (Blizzard's 3.5 s)");
    w.now += 400.msecs;
    me.runProcs(ProcFlag.takeMeleeSwing, attacker, swing);
    assert(shield.charges == 1, "3.6 s on: the next");
}

/**
 * Diminishing returns in PvP (patch 1.4.0): an orc warlock's Fear (6215, 20 s) on a flagged human lasts 20 s, then
 * 10, then 5, then not at all; 15 s after the last one ended, 20 again. Polymorph (118), which no 1.x patch note puts
 * in a category, is never diminished. The rule before: every Fear lasted 20 s.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

    auto w = RealWorld.make();
    auto lock = w.character(508, "Gulvar", 9, 60, [], raceOrc);
    auto mark = w.character(509, "Marcus", classWarriorId, 60, []);
    auto caster = cast(Character) lock.session.inWorld, victim = cast(Character) mark.session.inWorld;
    victim.player.values.set!UNIT_FIELD_FLAGS(victim.player.values.get!UNIT_FIELD_FLAGS | UnitFlags.pvp);
    int feared(uint spell)
    {
        caster.applyAuraEffect(spellOf(w, spell), 0, victim.player.guid);
        auto aura = victim.player.auras.find(spell);
        const lasts = aura is null ? 0 : aura.maxDuration;
        if (aura !is null)
            victim.removeAura(aura); // it ends (broken, say) at once
        w.now += 1.seconds;
        return lasts;
    }
    assert(feared(6215) == 20_000, "the first: whole");
    assert(feared(6215) == 10_000, "the second: half");
    assert(feared(6215) == 5000, "the third: a quarter");
    assert(feared(6215) == 0, "the fourth: immune");
    w.now += 15.seconds;
    assert(feared(6215) == 20_000, "15 s after the last ended: whole again");
    foreach (_; 0 .. 4)
        assert(feared(118) == 20_000, "Polymorph: no category");
}
