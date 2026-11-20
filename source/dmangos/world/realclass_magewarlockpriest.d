/**
 * The mage's, the warlock's and the priest's spells and talents on the real data (`dmangos.world.realspelltests`):
 * each test asserts what the spell's 1.12.1 tooltip says (docs/spells/mage.md, warlock.md, priest.md), for every
 * rank, on characters of the class. The talents that only modify other spells are tables (`ModRow`): the spells the
 * tooltip names, by the modifier the talent's data gives; each kind of modifier is then shown to do its work in a
 * cast (a cast time, a cooldown, a cost, a range, a crit's damage).
 */
module dmangos.world.realclass_magewarlockpriest;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.bytes : ByteReader;
import dmangos.world.auras : Aura, AuraType, makeAura;
import dmangos.world.character : Character;
import dmangos.world.creature : Creature;
import dmangos.world.defines : PlayerClass, Power;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : SpellCastResult;
import dmangos.world.spellmods : SpellModOp;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient;
import dmangos.world.updatefields;

// ---------------------------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------------------------

/// The spell logs of `opcode` (damage, heal, energize: a target, a caster, the spell, then its amount) since the
/// last read: spell and amount.
private uint[2][] spellLogs(ref TestClient who, ushort opcode)
{
    uint[2][] logs;
    foreach (p; who.read())
        if (p.opcode == opcode)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            const spell = r.read!uint;
            logs ~= [spell, r.read!uint];
        }
    return logs;
}

/// Time passes: for the character and its map, in steps of half a second at most.
private void pass(ref RealWorld w, ref TestClient who, Duration elapsed)
{
    while (elapsed > Duration.zero)
    {
        const step = elapsed > 500.msecs ? 500.msecs : elapsed;
        elapsed -= step;
        w.now += step;
        who.session.inWorld.update(step);
        w.context.map(0).update(step);
    }
}

/// The creature of `guid` on the map.
private Creature creatureOf(ref RealWorld w, ulong guid)
{
    return cast(Creature) w.context.map(0).findObject(guid);
}

/// The real spell `id`.
private const(SpellInfo)* spellOf(ref RealWorld w, uint id)
{
    const s = w.context.data.spells.spell(id);
    assert(s !is null, format!"no spell %s"(id));
    return s;
}

/// An aura of the real spell `id` on the character, as its own (`amount` its first effect's; the data's if none).
private Aura giveAura(ref RealWorld w, ref TestClient who, uint id, int amount = int.min, uint stacks = 1)
{
    import dmangos.world.spellcast : effectValue;

    auto me = who.session.inWorld;
    const s = spellOf(w, id);
    int[3] values;
    foreach (i; 0 .. 3)
        values[i] = effectValue(*s, i, 60, 0);
    if (amount != int.min)
        values[0] = amount;
    foreach (_; 0 .. stacks)
        me.addAura(makeAura(s, me.player.guid, 60, -1, true, values));
    return me.player.auras.find(id);
}

/// A talent rank learned: its passive aura on.
private void learn(ref RealWorld w, ref TestClient who, uint talent)
{
    auto me = who.session.inWorld;
    if (spellOf(w, talent).isPassive)
        me.applyPassive(spellOf(w, talent));
    else
        giveAura(w, who, talent);
    assert(me.player.auras.find(talent) !is null, format!"talent %s on"(talent));
}

/// Full mana (and health) again: for a test's many casts.
private void topUp(ref TestClient who)
{
    auto me = who.session.inWorld;
    me.player.values.set!UNIT_FIELD_POWER1(Power.mana, me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana));
    me.player.values.set!UNIT_FIELD_HEALTH(me.player.values.get!UNIT_FIELD_MAXHEALTH);
}

/// The talent's aura off again.
private void unlearn(ref TestClient who, uint talent)
{
    auto me = who.session.inWorld;
    if (auto aura = me.player.auras.find(talent))
        me.removeAura(aura);
}

/// A talent table's row: each rank of a talent changes property `op` of each of `spells` by the rank's `values` (a
/// flat amount, or a percent of `base`); `unaffected` spells it leaves as they are.
private struct ModRow
{
    string talent;
    const(uint)[] ranks;
    SpellModOp op;
    bool percent;
    const(int)[] values;
    const(uint)[] spells;
    int base = 1000;
    const(uint)[] unaffected;
}

/// Checks each row of `rows` on a character of `classId`: the talent's every rank, on each spell.
private void checkMods(ubyte classId, const(ModRow)[] rows)
{
    auto w = RealWorld.make();
    auto who = w.character(900 + classId, "Tabled", classId, 60, []);
    auto me = who.session.inWorld;
    string[] wrong;
    foreach (ref row; rows)
    {
        assert(row.ranks.length == row.values.length, row.talent);
        foreach (k, rank; row.ranks)
        {
            learn(w, who, rank);
            foreach (id; row.spells)
            {
                const expected = row.percent ? cast(int)(row.base * (100.0 + row.values[k]) / 100.0)
                    : row.base + row.values[k];
                const got = me.spellMod!int(row.op, spellOf(w, id), row.base);
                if (got != expected)
                    wrong ~= format!"%s (%s) on %s (%s): %s, not %s"(row.talent, rank, spellOf(w, id).casting.name,
                        id, got, expected);
            }
            foreach (id; row.unaffected)
                if (me.spellMod!int(row.op, spellOf(w, id), row.base) != row.base)
                    wrong ~= format!"%s (%s) changes %s (%s)"(row.talent, rank, spellOf(w, id).casting.name, id);
            unlearn(who, rank);
        }
    }
    import std.array : join;

    assert(!wrong.length, "\n" ~ wrong.join("\n"));
}

/// A kobold (or creature `entry`) two yards east of `who`, who faces it.
private ulong facedEnemy(ref RealWorld w, ref TestClient who, uint entry = 6)
{
    who.session.inWorld.player.movement.position.orientation = 0;
    return w.enemy(who, entry);
}

/// The cast time `SMSG_SPELL_START` gave for `spell` since the last read; -1 if none.
private int startedCastTime(ref TestClient who, uint spell)
{
    foreach (p; who.read())
        if (p.opcode == Opcode.SMSG_SPELL_START)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            if (r.read!uint != spell)
                continue;
            r.read!ushort;
            return cast(int) r.read!uint;
        }
    return -1;
}

enum ubyte mage = PlayerClass.mage, warlock = PlayerClass.warlock, priest = PlayerClass.priest;

// Spells of the tables.
private enum : uint
{
    fireball = 133, frostbolt = 116, blizzard = 10, scorch = 2948, fireBlast = 2136, flamestrike = 2120,
    pyroblast = 11366, blastWave = 11113, arcaneExplosion = 1449, frostNova = 122, coneOfCold = 120, iceBarrier = 11426,
    manaShield = 1463, amplifyMagic = 1008, dampenMagic = 604, counterspell = 2139, polymorph = 118, arcaneMissile = 7268,
    arcaneMissiles = 5143, chilled = 6136, iceArmorChill = 7321, frostArmor = 168, iceArmor = 7302, frostWard = 6143,
    fireWard = 543, arcaneIntellect = 1459,
}

// ---------------------------------------------------------------------------------------------------------------
// Mage
// ---------------------------------------------------------------------------------------------------------------

/// The mage's talents that modify spells: each rank, on the spells its tooltip names.
unittest
{
    if (!haveRealData())
        return;
    alias Op = SpellModOp;
    static immutable uint[] fire = [fireball, scorch, fireBlast, flamestrike, pyroblast, blastWave];
    static immutable uint[] frost = [frostbolt, coneOfCold, frostNova, blizzard];
    static immutable uint[] all = fire ~ frost ~ [arcaneExplosion, arcaneMissile];
    checkMods(mage, [
        ModRow("Arcane Focus", [11222, 12839, 12840, 12841, 12842], Op.resistMissChance, false, [2, 4, 6, 8, 10],
            [arcaneMissile, arcaneExplosion, counterspell, polymorph], 0, [fireball, frostbolt]),
        ModRow("Arcane Instability: damage", [15058, 15059, 15060], Op.damage, true, [1, 2, 3], all),
        ModRow("Arcane Instability: over time", [15058, 15059, 15060], Op.dot, true, [1, 2, 3],
            [fireball, pyroblast, flamestrike, blizzard]),
        ModRow("Arcane Instability: crit", [15058, 15059, 15060], Op.critChance, false, [1, 2, 3], all, 0),
        ModRow("Arctic Reach: range", [16757, 16758], Op.range, true, [10, 20], [frostbolt, blizzard], 30),
        ModRow("Arctic Reach: radius", [16757, 16758], Op.radius, true, [10, 20], [frostNova, coneOfCold], 10),
        ModRow("Burning Soul", [11083, 12351], Op.notLoseCastingTime, true, [35, 70], fire, 100, [frostbolt]),
        ModRow("Critical Mass", [11115, 11367, 11368], Op.critChance, false, [2, 4, 6], fire, 0, [frostbolt]),
        ModRow("Elemental Precision", [29438, 29439, 29440], Op.resistMissChance, false, [2, 4, 6], fire ~ frost, 0,
            [arcaneExplosion]),
        ModRow("Fire Power", [11124, 12378, 12398, 12399, 12400], Op.damage, true, [2, 4, 6, 8, 10], fire, 1000,
            [frostbolt]),
        ModRow("Fire Power: over time", [11124, 12378, 12398, 12399, 12400], Op.dot, true, [2, 4, 6, 8, 10],
            [fireball, pyroblast, flamestrike]),
        ModRow("Flame Throwing", [11100, 12353], Op.range, false, [3, 6], [fireball, scorch, fireBlast, pyroblast,
            flamestrike], 30, [frostbolt]),
        ModRow("Frost Channeling", [11160, 12518, 12519], Op.cost, true, [-5, -10, -15], frost ~ [iceBarrier,
            frostArmor, iceArmor, frostWard], 1000, [fireball]),
        ModRow("Ice Shards", [11207, 12672, 15047, 15052, 15053], Op.critDamageBonus, true, [20, 40, 60, 80, 100],
            frost, 100, [fireball]),
        ModRow("Improved Arcane Explosion", [11242, 12467, 12469], Op.critChance, false, [2, 4, 6], [arcaneExplosion],
            0, [arcaneMissile]),
        ModRow("Improved Arcane Missiles", [11237, 12463, 12464, 16769, 16770], Op.notLoseCastingTime, true,
            [20, 40, 60, 80, 100], [arcaneMissiles], 100),
        ModRow("Improved Cone of Cold", [11190, 12489, 12490], Op.damage, true, [15, 25, 35], [coneOfCold], 1000,
            [frostbolt]),
        ModRow("Improved Fire Blast", [11078, 11080, 12342], Op.cooldown, false, [-500, -1000, -1500], [fireBlast],
            8000),
        ModRow("Improved Fireball", [11069, 12338, 12339, 12340, 12341], Op.castingTime, false,
            [-100, -200, -300, -400, -500], [fireball], 3500, [frostbolt]),
        ModRow("Improved Flamestrike", [11108, 12349, 12350], Op.critChance, false, [5, 10, 15], [flamestrike], 0),
        ModRow("Improved Frost Nova", [11165, 12475], Op.cooldown, false, [-2000, -4000], [frostNova], 25_000),
        ModRow("Improved Frostbolt", [11070, 12473, 16763, 16765, 16766], Op.castingTime, false,
            [-100, -200, -300, -400, -500], [frostbolt], 3000, [fireball]),
        ModRow("Improved Mana Shield", [11252, 12605], Op.multipleValue, true, [-10, -20], [manaShield], 1000),
        ModRow("Incinerate", [18459, 18460], Op.critChance, false, [2, 4], [fireBlast, scorch], 0, [fireball]),
        ModRow("Magic Attunement", [11247, 12606], Op.allEffects, true, [25, 50], [amplifyMagic, dampenMagic], 100),
        ModRow("Permafrost: duration", [11175, 12569, 12571], Op.duration, false, [1000, 2000, 3000],
            [frostbolt, coneOfCold, chilled, iceArmorChill], 5000),
        ModRow("Piercing Ice", [11151, 12952, 12953], Op.damage, true, [2, 4, 6], [frostbolt, coneOfCold, frostNova],
            1000, [fireball]),
        ModRow("Piercing Ice: over time", [11151, 12952, 12953], Op.dot, true, [2, 4, 6], [blizzard], 1000),
        ModRow("Arcane Power: damage", [12042], Op.damage, true, [30], all),
        ModRow("Arcane Power: cost", [12042], Op.cost, true, [30], all),
        ModRow("Combustion's crit", [28682], Op.critChance, false, [10], fire, 0, [frostbolt]),
    ]);
}

/// A creature of `entry` `yards` east of `who` (who faces it), with health enough for many blows.
private ulong toughEnemy(ref RealWorld w, ref TestClient who, float yards = 2, uint entry = 6)
{
    import dmangos.world.creature : TempSpawnType;

    auto me = who.session.inWorld;
    me.player.movement.position.orientation = 0;
    auto at = me.player.position;
    at.x += yards;
    auto creature = w.context.summonCreature(w.context.map(0), entry, at, TempSpawnType.manual, 0, 0);
    assert(creature !is null);
    creature.values.set!UNIT_FIELD_MAXHEALTH(10_000_000u);
    creature.values.set!UNIT_FIELD_HEALTH(10_000_000u);
    import dmangos.world.creatureai : ReactState;

    creature.ai.react = ReactState.passive; // it stands: no blows to push casts back
    who.read();
    return creature.guid;
}

/// A swing of `damage` by `attacker` lands on `who`.
private void swingAt(ref RealWorld w, ref TestClient who, ulong attacker, uint damage, bool crit = false)
{
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.unit : Blow, dealDamage;

    auto me = who.session.inWorld;
    MeleeDamage d;
    d.attacker = attacker;
    d.target = me.player.guid;
    d.outcome = crit ? MeleeHitOutcome.crit : MeleeHitOutcome.normal;
    d.damage = damage;
    dealDamage(w.context.map(0).unit(attacker), me.unit, damage, Blow.swing(d));
}

/// Frost Nova (10230) cast until it roots the kobold (a spell may miss).
private void novaUntilFrozen(ref RealWorld w, ref TestClient who, ulong kobold)
{
    foreach (_; 0 .. 10)
    {
        if (creatureOf(w, kobold).auras.find(10230) !is null)
            return;
        w.now += 26.seconds;
        topUp(who);
        assert(w.cast_(who, 10230) == SpellCastResult.ok);
    }
}

/// The least and the most effect `i` of `spell` rolls at level 60.
private int[2] rolls(ref RealWorld w, uint spell, size_t i)
{
    import dmangos.world.spellcast : effectValue;

    const s = spellOf(w, spell);
    return [effectValue(*s, i, 60, 0), effectValue(*s, i, 60, 0.999)];
}

/// The cast time modifiers (Improved Fireball, Improved Frostbolt) shorten the cast the client is told of: Fireball
/// rank 11 (10151: 3.5 sec) 3 sec, Frostbolt rank 10 (10181: 3 sec) 2.5 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1001, "Fastcaster", mage, 60, [10151, 10181]);
    learn(w, who, 12341);
    learn(w, who, 16766);
    const target = toughEnemy(w, who, 10);
    foreach (spell, expected; [10151: 3000, 10181: 2500])
    {
        who.read();
        topUp(who);
        assert(w.castAt(who, spell, target) == SpellCastResult.ok);
        assert(startedCastTime(who, spell) == expected, format!"%s: %s ms"(spell, expected));
        pass(w, who, 4.seconds);
    }
}

/// Improved Fire Blast rank 3 (12342): Fire Blast (10199) ready again 6.5 sec on, not 8.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1002, "Blaster", mage, 60, [10199]);
    auto me = who.session.inWorld;
    learn(w, who, 12342);
    const target = toughEnemy(w, who, 10);
    topUp(who);
    assert(w.castAt(who, 10199, target) == SpellCastResult.ok);
    w.now += 6400.msecs;
    assert(!me.spellIsReady(10199), "not yet at 6.4 sec");
    w.now += 200.msecs;
    assert(me.spellIsReady(10199), "ready at 6.6 sec");
}

/// Frost Channeling rank 3 (12519): Frostbolt rank 10 (10181) costs 15% less mana; Arcane Power (12042) 30% more.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1003, "Cheapfrost", mage, 60, [10181]);
    auto me = who.session.inWorld;
    const full = me.costOf(*spellOf(w, 10181));
    learn(w, who, 12519);
    assert(me.costOf(*spellOf(w, 10181)) == cast(int)(full * 0.85), "15% less");
    const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
    const target = toughEnemy(w, who, 10);
    assert(w.castAt(who, 10181, target) == SpellCastResult.ok);
    pass(w, who, 4.seconds);
    assert(mana - me.player.values.get!UNIT_FIELD_POWER1(Power.mana) == cast(int)(full * 0.85), "paid");
    unlearn(who, 12519);
    giveAura(w, who, 12042);
    assert(me.costOf(*spellOf(w, 10181)) == cast(int)(full * 1.3), "Arcane Power: 30% more");
}

/// Flame Throwing rank 2 (12353): Fireball (10151, 35 yards) reaches a target 39 yards off.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1004, "Longshot", mage, 60, [10151]);
    const target = toughEnemy(w, who, 39);
    topUp(who);
    assert(w.castAt(who, 10151, target) == SpellCastResult.outOfRange, "out of range without the talent");
    learn(w, who, 12353);
    w.now += 2.seconds;
    topUp(who);
    const r = w.castAt(who, 10151, target);
    assert(r == SpellCastResult.ok, format!"6 yards more: %s"(r));
}

/// Arctic Reach rank 2 (16758): Frost Nova (10230, 10 yards) roots a kobold 11 yards off.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1005, "Wide", mage, 60, [10230]);
    learn(w, who, 16758);
    const kobold = toughEnemy(w, who, 11, 6);
    novaUntilFrozen(w, who, kobold);
    assert(creatureOf(w, kobold).auras.find(10230) !is null, "rooted 11 yards off");
}

/**
 * The damage modifiers count the spell power's share too ("the damage done by your Fire spells"): Fire Power rank 5
 * (12400) makes Fire Blast rank 7 (10199) with 1000 spell damage 10% more, the whole of it; Pyroblast's (12526)
 * damage over time too.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1006, "Pyro", mage, 60, [10199, 12526]);
    auto me = who.session.inWorld;
    giveAura(w, who, 17150, 1000); // Arcane Might: 1000 spell damage
    learn(w, who, 12400);
    const bonus = me.spellDamageBonus(spellOf(w, 10199), 2);
    assert(bonus > 300);
    const r = rolls(w, 10199, 0);
    const target = toughEnemy(w, who, 10);
    uint[] hits;
    foreach (_; 0 .. 6)
    {
        who.read();
        topUp(who);
        w.castAt(who, 10199, target);
        foreach (l; spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
            if (l[0] == 10199 && l[1])
                hits ~= l[1];
        w.now += 9.seconds;
    }
    assert(hits.length);
    foreach (h; hits)
    {
        const low = cast(uint)((r[0] + bonus) * 1.1), high = cast(uint)((r[1] + bonus) * 1.1) + 1;
        assert(h >= low && h <= high || h >= low * 3 / 2 && h <= high * 3 / 2 + 1,
            format!"%s: 10%% of %s to %s with the spell power"(h, r[0] + bonus, r[1] + bonus));
    }
    // Pyroblast rank 8's damage over time: its 3-second ticks, the spell power's share in them, 10% more.
    import dmangos.world.spellcast : bonusCoefficient;

    w.now += 2.seconds;
    who.read();
    topUp(who);
    assert(w.castAt(who, 12526, target) == SpellCastResult.ok);
    pass(w, who, 9.seconds); // (the kobold's blows push it back)
    auto burn = creatureOf(w, target).auras.find(12526);
    assert(burn !is null, "burning");
    const tick = rolls(w, 12526, 1)[0] + cast(int)(1000 * bonusCoefficient(*spellOf(w, 12526), 1, w.context.client, 60));
    assert(burn.amount[1] == cast(int)(tick * 1.1), format!"a tick %s, not %s"(burn.amount[1], cast(int)(tick * 1.1)));
}

/// Ice Shards rank 5 (15053): a Frostbolt's (10181) crit deals double, not half again; Fireball's (10151) still half.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1007, "Shards", mage, 60, []);
    auto me = who.session.inWorld;
    learn(w, who, 15053);
    assert(me.critDamage(spellOf(w, 10181), 1000) == 2000, "double");
    assert(me.critDamage(spellOf(w, 10151), 1000) == 1500, "fire: half again");
}

/// Elemental Precision rank 3 (29440) and Arcane Focus rank 5 (12842): the hit chance their spells are rolled with.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1008, "Precise", mage, 60, []);
    auto me = who.session.inWorld;
    learn(w, who, 29440);
    learn(w, who, 12842);
    assert(me.spellHitBonusOf(spellOf(w, 10181)) == 6 && me.spellHitBonusOf(spellOf(w, 10151)) == 6);
    assert(me.spellHitBonusOf(spellOf(w, 10273)) == 10, "an arcane missile");
}

/// Frost Channeling rank 3 (12519): Frostbolt's threat 30% less (`MOD_THREAT` for frost).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1009, "Quiet", mage, 60, [10181]);
    auto me = who.session.inWorld;
    learn(w, who, 12519);
    const target = toughEnemy(w, who, 10);
    who.read();
    topUp(who);
    assert(w.castAt(who, 10181, target) == SpellCastResult.ok);
    pass(w, who, 4.seconds);
    uint dealt;
    foreach (l; spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
        if (l[0] == 10181)
            dealt += l[1];
    assert(dealt, "struck");
    import std.math : isClose;

    const threat = creatureOf(w, target).ai.threatOf(me.player.guid);
    assert(isClose(threat, dealt * 0.7f, 0.01), format!"threat %s of %s damage"(threat, dealt));
}

/// Improved Arcane Missiles rank 5 (16770): blows do not shorten the channel of Arcane Missiles (10212).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1010, "Steady", mage, 60, [10212]);
    auto me = who.session.inWorld;
    const target = toughEnemy(w, who, 10);
    bool shortened()
    {
        w.now += 6.seconds;
        pass(w, who, 6.seconds);
        who.read();
        topUp(who);
        assert(w.castAt(who, 10212, target) == SpellCastResult.ok);
        foreach (_; 0 .. 5)
            me.damagedWhileCasting(false, false);
        return who.read().canFind!(p => p.opcode == Opcode.MSG_CHANNEL_UPDATE);
    }
    assert(shortened(), "without the talent");
    learn(w, who, 16770);
    assert(!shortened(), "with it, never");
}

/// Magic Attunement rank 2 (12606): Amplify Magic rank 4 (10170) amplifies half again as much.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1011, "Attuned", mage, 60, [10170]);
    auto me = who.session.inWorld;
    const plain = rolls(w, 10170, 0)[0];
    learn(w, who, 12606);
    topUp(who);
    assert(w.cast_(who, 10170) == SpellCastResult.ok);
    auto aura = me.player.auras.find(10170);
    assert(aura !is null && aura.amount[0] == plain * 3 / 2, format!"%s"(aura is null ? 0 : aura.amount[0]));
}

/// Improved Mana Shield rank 2 (12605): Mana Shield (10193) drains 1.6 mana a point absorbed, not 2.
unittest
{
    import dmangos.world.unit : Blow, UnitRef;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1012, "Shielded", mage, 60, [10193]);
    auto me = who.session.inWorld;
    learn(w, who, 12605);
    topUp(who);
    assert(w.cast_(who, 10193) == SpellCastResult.ok);
    const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
    uint damage = 100;
    assert(me.absorbIncoming(0, damage) == 100 && damage == 0, "absorbed");
    assert(mana - me.player.values.get!UNIT_FIELD_POWER1(Power.mana) == 160, format!"%s mana"(mana
        - me.player.values.get!UNIT_FIELD_POWER1(Power.mana)));
}

/// Each rank's proc chance is its tooltip's: `ranks[k]` procs `chances[k]`% of the time.
private void assertChances(ref RealWorld w, string talent, const(uint)[] ranks, const(uint)[] chances)
{
    foreach (k, rank; ranks)
        assert(spellOf(w, rank).casting.procChance == chances[k], format!"%s rank %s: %s%%"(talent, k + 1, chances[k]));
}

/// The aura of `spell` on the creature `guid`, or null.
private Aura auraOn(ref RealWorld w, ulong guid, uint spell)
{
    return creatureOf(w, guid).auras.find(spell);
}

/// A persistent area spell (Blizzard) cast at the spot of `target`.
private SpellCastResult castAtSpot(ref RealWorld w, ref TestClient who, uint spell, ulong target)
{
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    const at = creatureOf(w, target).position;
    SpellTargets t;
    t.mask = TargetFlags.destLocation;
    t.dest = [at.x, at.y, at.z];
    return who.session.inWorld.castSpell(spellOf(w, spell), t, false, 0);
}

/**
 * Arcane Concentration (2% a rank): a damage spell that hits may give Clearcasting (12536), which makes the next
 * damage spell free and goes with it. Blizzard's ticks give it too, by the rank's override script (1392); without the
 * script, its ticks (no spell hits) give none.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    assertChances(w, "Arcane Concentration", [11213, 12574, 12575, 12576, 12577], [2, 4, 6, 8, 10]);
    auto who = w.character(1020, "Concentrated", mage, 60, [10202, 10187]);
    auto me = who.session.inWorld;
    learn(w, who, 12577);
    const kobold = toughEnemy(w, who, 3);
    bool clear;
    foreach (_; 0 .. 200)
    {
        w.now += 2.seconds;
        me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 5000u);
        assert(w.cast_(who, 10202) == SpellCastResult.ok);
        if (me.player.auras.find(12536) !is null)
        {
            clear = true;
            break;
        }
    }
    assert(clear, "Clearcasting from Arcane Explosion's hits");
    w.now += 2.seconds;
    const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
    unlearn(who, 12577); // (no new Clearcasting from this one)
    assert(w.cast_(who, 10202) == SpellCastResult.ok);
    assert(me.player.values.get!UNIT_FIELD_POWER1(Power.mana) == mana, "free");
    assert(me.player.auras.find(12536) is null, "and spent");
    // Blizzard: three kobolds under it, its eight ticks.
    const more = [kobold, toughEnemy(w, who, 4), toughEnemy(w, who, 5)];
    bool blizzardClears(bool script)
    {
        learn(w, who, 12577);
        if (!script)
            me.player.auras.find(12577).effects &= ~2;
        scope (exit)
            unlearn(who, 12577);
        foreach (_; 0 .. 10)
        {
            w.now += 2.seconds;
            me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 5000u);
            assert(castAtSpot(w, who, 10187, more[1]) == SpellCastResult.ok);
            pass(w, who, 9.seconds);
            if (auto c = me.player.auras.find(12536))
            {
                me.removeAura(c);
                return true;
            }
        }
        return false;
    }
    assert(blizzardClears(true), "Blizzard's ticks, by the script");
    assert(!blizzardClears(false), "not without it");
}

/// Impact (2% a rank): a fire spell stuns its target (12355) for 2 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    assertChances(w, "Impact", [11103, 12357, 12358, 12359, 12360], [2, 4, 6, 8, 10]);
    auto who = w.character(1021, "Impactful", mage, 60, [10199]);
    learn(w, who, 12360);
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 150)
    {
        w.now += 9.seconds;
        topUp(who);
        w.castAt(who, 10199, target);
        if (auto stun = auraOn(w, target, 12355))
        {
            assert(stun.maxDuration == 2000, "2 sec");
            return;
        }
    }
    assert(false, "never stunned");
}

/// Improved Counterspell (50%, 100%): Counterspell (2139) silences its target (18469) for 4 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    assertChances(w, "Improved Counterspell", [11255, 12598], [50, 100]);
    auto who = w.character(1022, "Silencer", mage, 60, [2139]);
    learn(w, who, 12598);
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 5) // (until it lands: a spell may miss)
    {
        if (auraOn(w, target, 2139) !is null || auraOn(w, target, 18469) !is null)
            break;
        w.now += 31.seconds;
        topUp(who);
        assert(w.castAt(who, 2139, target) == SpellCastResult.ok);
    }
    auto silence = auraOn(w, target, 18469);
    assert(silence !is null && silence.maxDuration == 4000, "silenced for 4 sec");
}

/**
 * Winter's Chill (20% a rank): frost damage spells chill their target (12579), 2% more crit for frost spells a stack,
 * five at most; a fire spell crits no more often.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    assertChances(w, "Winter's Chill", [11180, 28592, 28593, 28594, 28595], [20, 40, 60, 80, 100]);
    auto who = w.character(1023, "Chiller", mage, 60, [116]);
    learn(w, who, 28595);
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 7)
    {
        topUp(who);
        assert(w.castAt(who, 116, target) == SpellCastResult.ok);
        pass(w, who, 2.seconds);
    }
    auto chill = auraOn(w, target, 12579);
    assert(chill !is null && chill.stacks == 5, format!"five stacks: %s"(chill is null ? 0 : chill.stacks));
    auto c = creatureOf(w, target);
    assert(Character.spellCritTaken(c.auras, 4) == 10, "frost: 10%");
    assert(Character.spellCritTaken(c.auras, 2) == 0, "fire: none");
}

/// Frostbite (5% a rank): a chill (Frostbolt's) may freeze its target (12494) for 5 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1024, "Biter", mage, 60, [116]);
    foreach (k, rank; [11071u, 12496, 12497])
        assert(rolls(w, rank, 0)[0] == 5 * (k + 1));
    learn(w, who, 12497);
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 80)
    {
        topUp(who);
        w.castAt(who, 116, target);
        pass(w, who, 2.seconds);
        if (auto frozen = auraOn(w, target, 12494))
        {
            assert(frozen.maxDuration == 5000);
            return;
        }
    }
    assert(false, "never frozen");
}

/// Improved Scorch (33% a rank): Scorch leaves Fire Vulnerability (22959): 3% more fire damage a stack, five at most.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1025, "Scorcher", mage, 60, [2948]);
    foreach (k, rank; [11095u, 12872, 12873])
        assert(rolls(w, rank, 0)[0] == [33, 66, 100][k]);
    learn(w, who, 12873);
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 7)
    {
        topUp(who);
        assert(w.castAt(who, 2948, target) == SpellCastResult.ok);
        pass(w, who, 2.seconds);
    }
    auto vulnerable = auraOn(w, target, 22959);
    assert(vulnerable !is null && vulnerable.stacks == 5);
    import std.math : isClose;

    assert(isClose(creatureOf(w, target).fighter.damageTaken[2], 1.15f, 0.001), "15% more fire damage");
}

/**
 * Ignite (8% a rank): a fire crit burns its target for a share of it over 4 sec (12654, two ticks of half of it);
 * Master of Elements (10% a rank) gives back a share of a fire or frost crit's base mana cost (29077).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1026, "Igniter", mage, 60, [10199]);
    auto me = who.session.inWorld;
    learn(w, who, 12848);
    learn(w, who, 29076);
    giveAura(w, who, 23434, 100); // every spell a crit
    const target = toughEnemy(w, who, 10);
    uint crit;
    uint[2][] energized;
    foreach (attempt; 0 .. 10) // (until one lands: a spell may miss)
    foreach (p; crit ? null : () { w.now += 9.seconds; who.read(); topUp(who);
        assert(w.castAt(who, 10199, target) == SpellCastResult.ok); return who.read(); }())
    {
        auto r = ByteReader(p.body_);
        if (p.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
        {
            r.readPackedGuid();
            r.readPackedGuid();
            if (r.read!uint == 10199)
                crit = r.read!uint;
        }
        else if (p.opcode == Opcode.SMSG_SPELLENERGIZELOG)
        {
            r.readPackedGuid();
            r.readPackedGuid();
            const spell = r.read!uint;
            r.read!uint;
            energized ~= [spell, r.read!uint];
        }
    }
    assert(crit);
    auto burn = auraOn(w, target, 12654);
    assert(burn !is null && burn.maxDuration == 4000);
    assert(burn.amount[0] == crit * 20 / 100, format!"a tick %s of a crit of %s"(burn.amount[0], crit));
    const cost = spellOf(w, 10199).casting.manaCost;
    assert(energized.canFind([29077u, cast(uint)(cost * 30 / 100)]), format!"30%% of %s back: %s"(cost, energized));
}

/**
 * Combustion (11129): each fire spell that hits adds 10% crit chance (28682) to the fire spells; the third crit ends
 * it.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1027, "Combusted", mage, 60, [11129, 10199]);
    auto me = who.session.inWorld;
    const target = toughEnemy(w, who, 10);
    topUp(who);
    assert(w.cast_(who, 11129) == SpellCastResult.ok);
    assert(me.player.auras.find(11129).charges == 3);
    w.now += 2.seconds;
    auto stacks = me.player.auras.find(28682);
    assert(stacks !is null && stacks.stacks == 1, "its first 10% at once");
    const before = me.critChanceOf(spellOf(w, 10199), w.context.map(0).unit(target));
    topUp(who);
    w.castAt(who, 10199, target);
    assert(stacks.stacks == 2 || me.player.auras.find(11129).charges == 2, "a stack more, or a crit");
    import std.math : isClose;

    assert(isClose(me.critChanceOf(spellOf(w, 10199), w.context.map(0).unit(target)), before + 10 * (stacks.stacks - 1),
        0.01), "10% a stack");
    foreach (_; 0 .. 60)
    {
        if (me.player.auras.find(11129) is null)
            break;
        w.now += 9.seconds;
        topUp(who);
        w.castAt(who, 10199, target);
    }
    assert(me.player.auras.find(11129) is null && me.player.auras.find(28682) is null, "gone at the third crit");
}

/// Frost Armor (7301) and Ice Armor (10220): a swing at the mage chills its striker (6136, 7321: 30% slower, attacks
/// 25% slower); Frost Warding rank 2 (28332) gives them 30% more armor.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1028, "Armored", mage, 60, [7301, 10220]);
    auto me = who.session.inWorld;
    foreach (armor, chill; [7301: 6136, 10220: 7321])
    {
        w.now += 2.seconds;
        topUp(who);
        assert(w.cast_(who, armor) == SpellCastResult.ok);
        const striker = toughEnemy(w, who);
        foreach (_; 0 .. 5) // (the chill, a spell, may miss)
            if (auraOn(w, striker, chill) is null)
                swingAt(w, who, striker, 10);
        assert(auraOn(w, striker, chill) !is null, format!"%s chills its striker"(armor));
    }
    const plain = me.player.auras.find(10220).amount[0];
    learn(w, who, 28332);
    w.now += 2.seconds;
    topUp(who);
    assert(w.cast_(who, 10220) == SpellCastResult.ok);
    assert(me.player.auras.find(10220).amount[0] == plain * 13 / 10, "30% more armor");
    assert(me.player.auras.find(10220).amount[2] == 15 * 13 / 10, "and frost resistance");
}

/// Improved Blizzard (30%, 50%, 65%): Blizzard's (10187) ticks chill (12484, 12485, 12486) for 1.5 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1029, "Blizzarder", mage, 60, [10187]);
    foreach (k, rank; [11185u, 12487, 12488])
    {
        learn(w, who, rank);
        const kobold = toughEnemy(w, who, 10);
        w.now += 10.seconds;
        topUp(who);
        assert(castAtSpot(w, who, 10187, kobold) == SpellCastResult.ok);
        pass(w, who, 1500.msecs);
        const chill = [12484u, 12485, 12486][k];
        auto slow = auraOn(w, kobold, chill);
        assert(slow !is null && slow.amount[0] == -[30, 50, 65][k] && slow.maxDuration == 1500,
            format!"rank %s chills"(k + 1));
        pass(w, who, 8.seconds);
        unlearn(who, rank);
    }
}

/// Shatter (10% a rank): the crit chance against a frozen target (Frost Nova's) is more.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1030, "Shatterer", mage, 60, [10230]);
    auto me = who.session.inWorld;
    const kobold = toughEnemy(w, who, 5);
    novaUntilFrozen(w, who, kobold);
    assert(auraOn(w, kobold, 10230) !is null, "frozen");
    auto target = w.context.map(0).unit(kobold);
    const plain = me.critChanceOf(spellOf(w, 10181), target);
    import std.math : isClose;

    foreach (k, rank; [11170u, 12982, 12983, 12984, 12985])
    {
        learn(w, who, rank);
        assert(isClose(me.critChanceOf(spellOf(w, 10181), target), plain + 10 * (k + 1), 0.01), "10% a rank");
        unlearn(who, rank);
    }
}

/**
 * Permafrost (1, 2, 3 sec; 4%, 7%, 10%): the chills last longer and slow more: Frostbolt's (116) slow 3 sec longer
 * and 10% more; its damage as it was.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1031, "Permafrosted", mage, 60, [116]);
    auto me = who.session.inWorld;
    learn(w, who, 12571);
    assert(me.effectMod(spellOf(w, 116), 1, 100) == 100, "the damage untouched");
    assert(me.effectMod(spellOf(w, 116), 0, -40) == -50, "10% slower");
    assert(me.effectMod(spellOf(w, 6136), 1, -30) == -40, "Frost Armor's chill too");
    const target = toughEnemy(w, who, 10);
    topUp(who);
    assert(w.castAt(who, 116, target) == SpellCastResult.ok);
    pass(w, who, 2.seconds);
    auto slow = auraOn(w, target, 116);
    assert(slow !is null && slow.maxDuration == 5000 + 3000 && slow.amount[0] == -50);
}

/// Teleport (3561, 3562, 3563, 3565, 3566, 3567): the mage is in the city.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    static immutable float[4][uint] cities = [3561: [0, -9003.46, 870.031, 29.6206], 3562: [0, -4613.62, -915.38,
        501.062], 3563: [0, 1773.47, 61.121, -46.3207], 3565: [1, 9664.14, 2526.36, 1334.27], 3566: [1, -964.98,
        283.433, 111.187], 3567: [1, 1469.85, -4221.52, 58.9939]];
    foreach (spell, at; cities)
    {
        auto who = w.character(1040 + spell % 100, format!"Porter%s"(spell % 100), mage, 60, [spell]);
        auto me = who.session.inWorld;
        me.storeLoot(17031, 1, 0, false); // a Rune of Teleportation, its reagent
        topUp(who);
        const r = w.cast_(who, spell);
        assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
        pass(w, who, 11.seconds);
        import std.math : abs;

        assert(me.player.data.map == cast(uint) at[0] && abs(me.player.position.x - at[1]) < 1
            && abs(me.player.position.y - at[2]) < 1, format!"%s: at %s"(spell, me.player.position));
    }
}

/// Arcane Missiles rank 1 (5143): a missile (7268) a second for 3 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1032, "Missiler", mage, 60, [5143]);
    const target = toughEnemy(w, who, 10);
    who.read();
    topUp(who);
    assert(w.castAt(who, 5143, target) == SpellCastResult.ok);
    pass(w, who, 4.seconds);
    // Each missile shot (`SMSG_SPELL_GO`; one may miss, and log no damage).
    uint missiles;
    foreach (p; who.read())
        if (p.opcode == Opcode.SMSG_SPELL_GO)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            missiles += r.read!uint == 7268;
        }
    assert(missiles == 3, format!"%s missiles"(missiles));
}

// ---------------------------------------------------------------------------------------------------------------
// Warlock
// ---------------------------------------------------------------------------------------------------------------

private enum : uint
{
    shadowBolt = 686, immolate = 348, searingPain = 5676, soulFire = 6353, rainOfFire = 5740, hellfire = 1949,
    hellfireEffect = 5857, conflagrate = 17962, shadowburn = 17877, corruption = 172, curseOfAgony = 980,
    curseOfDoom = 603, curseOfExhaustion = 18223, curseOfRecklessness = 704, curseOfShadow = 17862,
    curseOfTongues = 1714, curseOfWeakness = 702, curseOfTheElements = 1490, drainLife = 689, drainMana = 5138,
    drainSoul = 1120, deathCoil = 6789, fear = 5782, howlOfTerror = 5484, siphonLife = 18265, healthFunnel = 755,
    summonImp = 688, summonVoidwalker = 697, summonSuccubus = 712, summonFelhunter = 691, lifeTap = 1454,
}

/// The warlock's talents that modify spells: each rank, on the spells its tooltip names.
unittest
{
    if (!haveRealData())
        return;
    alias Op = SpellModOp;
    static immutable uint[] destruction = [shadowBolt, immolate, searingPain, soulFire, rainOfFire, hellfire,
        conflagrate, shadowburn];
    static immutable uint[] affliction = [corruption, curseOfAgony, curseOfDoom, curseOfExhaustion,
        curseOfRecklessness, curseOfShadow, curseOfTongues, curseOfWeakness, curseOfTheElements, drainLife, drainMana,
        drainSoul, deathCoil, fear, howlOfTerror, siphonLife];
    static immutable uint[] summons = [summonImp, summonVoidwalker, summonSuccubus, summonFelhunter];
    checkMods(warlock, [
        ModRow("Bane", [17788, 17789, 17790, 17791, 17792], Op.castingTime, false, [-100, -200, -300, -400, -500],
            [shadowBolt, immolate], 3000, [searingPain]),
        ModRow("Bane: Soul Fire", [17788, 17789, 17790, 17791, 17792], Op.castingTime, false,
            [-400, -800, -1200, -1600, -2000], [soulFire], 6000),
        ModRow("Cataclysm", [17778, 17779, 17780, 17781, 17782], Op.cost, true, [-1, -2, -3, -4, -5], destruction,
            1000, [corruption]),
        ModRow("Destructive Reach", [17917, 17918], Op.range, true, [10, 20], destruction, 30, [corruption]),
        ModRow("Devastation", [18130, 18131, 18132, 18133, 18134], Op.critChance, false, [1, 2, 3, 4, 5],
            destruction, 0, [corruption]),
        ModRow("Emberstorm", [17954, 17955, 17956, 17957, 17958], Op.damage, true, [2, 4, 6, 8, 10],
            [immolate, searingPain, soulFire, conflagrate, hellfireEffect], 1000, [shadowBolt]),
        ModRow("Emberstorm: over time", [17954, 17955, 17956, 17957, 17958], Op.dot, true, [2, 4, 6, 8, 10],
            [immolate, rainOfFire], 1000, [corruption]),
        ModRow("Fel Concentration", [17783, 17784, 17785, 17786, 17787], Op.notLoseCastingTime, true,
            [14, 28, 42, 56, 70], [drainLife, drainMana, drainSoul], 100),
        ModRow("Grim Reach", [18218, 18219], Op.range, true, [10, 20], affliction, 30, [shadowBolt]),
        ModRow("Improved Corruption", [17810, 17811, 17812, 17813, 17814], Op.castingTime, false,
            [-400, -800, -1200, -1600, -2000], [corruption], 2000),
        ModRow("Improved Curse of Agony", [18827, 18829, 18830], Op.allEffects, true, [2, 4, 6], [curseOfAgony],
            1000),
        ModRow("Improved Curse of Weakness", [18179, 18180, 18181], Op.allEffects, true, [6, 13, 20],
            [curseOfWeakness], 1000),
        ModRow("Improved Drain Life", [17804, 17805, 17806, 17807, 17808], Op.allEffects, true, [2, 4, 6, 8, 10],
            [drainLife], 1000),
        ModRow("Improved Drain Soul", [18213, 18372], Op.chanceOfSuccess, false, [50, 100], [drainSoul], 0),
        ModRow("Improved Health Funnel", [18703, 18704], Op.allEffects, true, [10, 20], [healthFunnel], 1000),
        ModRow("Improved Immolate", [17815, 17833, 17834, 17835, 17836], Op.damage, true, [5, 10, 15, 20, 25],
            [immolate], 1000, [searingPain]),
        ModRow("Improved Searing Pain", [17927, 17929, 17930, 17931, 17932], Op.critChance, false, [2, 4, 6, 8, 10],
            [searingPain], 0, [shadowBolt]),
        ModRow("Intensity", [18135, 18136], Op.notLoseCastingTime, true, [35, 70], [rainOfFire, hellfire, soulFire],
            100),
        ModRow("Master Summoner: cast time", [18709, 18710], Op.castingTime, false, [-2000, -4000], summons, 10_000),
        ModRow("Master Summoner: cost", [18709, 18710], Op.cost, true, [-20, -40], summons, 1000),
        ModRow("Fel Domination: cast time", [18708], Op.castingTime, false, [-5500], summons, 10_000),
        ModRow("Fel Domination: cost", [18708], Op.cost, true, [-50], summons, 1000),
        ModRow("Ruin", [17959], Op.critDamageBonus, true, [100], destruction, 100, [corruption]),
        ModRow("Shadow Mastery: damage", [18271, 18272, 18273, 18274, 18275], Op.damage, true, [2, 4, 6, 8, 10],
            [shadowBolt, shadowburn, deathCoil], 1000, [immolate]),
        ModRow("Shadow Mastery: over time", [18271, 18272, 18273, 18274, 18275], Op.dot, true, [2, 4, 6, 8, 10],
            [corruption, curseOfAgony, curseOfDoom, drainLife, drainSoul, siphonLife], 1000, [immolate]),
        ModRow("Suppression", [18174, 18175, 18176, 18177, 18178], Op.resistMissChance, false, [2, 4, 6, 8, 10],
            affliction, 0, [shadowBolt]),
        ModRow("Amplify Curse", [18288], Op.allEffects, true, [50], [curseOfAgony, curseOfWeakness], 1000,
            [curseOfTongues]),
    ]);
}

/**
 * Improved Curse of Exhaustion (5% a rank) and Amplify Curse (20%): Curse of Exhaustion (18223) slows 10% more a
 * rank... by their second effect's modifier, which is its slow (its only effect).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1101, "Exhauster", warlock, 60, [18223]);
    auto me = who.session.inWorld;
    foreach (k, rank; [18310u, 18311, 18312, 18313])
    {
        learn(w, who, rank);
        assert(me.effectMod(spellOf(w, 18223), 0, -10) == -10 - 5 * cast(int)(k + 1), format!"rank %s"(k + 1));
        unlearn(who, rank);
    }
    giveAura(w, who, 18288);
    assert(me.effectMod(spellOf(w, 18223), 0, -10) == -30, "Amplify Curse: 20% more");
}

/// A creature casting `spell` at `who` (triggered: no cast time, no mana), as its own spell.
private void creatureCasts(ref RealWorld w, ulong creature, uint spell, ref TestClient who)
{
    import dmangos.world.eventai : castTriggered, castForceCast;

    pass(w, who, 100.msecs); // (the creature's AI knows its world once updated)
    const ok = creatureOf(w, creature).ai.castSpell(spellOf(w, spell), who.session.inWorld.player.guid,
        castTriggered | castForceCast);
    assert(ok, format!"the creature cast %s: %s"(spell, creatureOf(w, creature).ai.castRefusal));
}

/**
 * Magic Absorption (2 resistances and 1% a rank): all resistances more; a spell resisted whole gives back 5% of the
 * mana (29442), once a second at most.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1050, "Absorber", mage, 60, []);
    auto me = who.session.inWorld;
    const before = me.player.values.get!UNIT_FIELD_RESISTANCES(4);
    learn(w, who, 29447);
    foreach (school; 2 .. 7) // (the magic schools a player resists: no holy)
        assert(me.player.values.get!UNIT_FIELD_RESISTANCES(school) >= 10, "10 more of each");
    assert(me.player.values.get!UNIT_FIELD_RESISTANCES(4) == before + 10);
    const kobold = toughEnemy(w, who, 10); // a level 1 kobold: its spells at a level 60 mage mostly missed
    const max = me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana);
    bool back;
    foreach (_; 0 .. 40)
    {
        w.now += 2.seconds;
        me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 0u);
        who.read();
        creatureCasts(w, kobold, 116, who);
        if (spellLogs(who, Opcode.SMSG_SPELLENERGIZELOG).canFind!(l => l[0] == 29442))
        {
            assert(me.player.values.get!UNIT_FIELD_POWER1(Power.mana) == max * 5 / 100, "5% of the mana");
            back = true;
            break;
        }
    }
    assert(back, "mana back from a resisted Frostbolt");
}

/// Frost Warding (10%, 20%) and Improved Fire Ward (10%, 20%): Frost Ward (6143) and Fire Ward (543) send a spell
/// of their school back at its caster.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (ward, row; [6143u: [28332u, 116, 4], 543u: [13043u, 133, 2]])
    {
        auto who = w.character(1051 + row[2], format!"Warder%s"(row[2]), mage, 60, [ward, row[0]]);
        auto me = who.session.inWorld;
        const caster = toughEnemy(w, who, 10);
        creatureOf(w, caster).values.set!UNIT_FIELD_LEVEL(60u); // (of the mage's level: its spells mostly land)
        uint back;
        foreach (_; 0 .. 60)
        {
            if (me.player.auras.find(ward) is null)
            {
                w.now += 31.seconds;
                topUp(who);
                assert(w.cast_(who, ward) == SpellCastResult.ok);
            }
            me.player.auras.find(ward).amount[0] = 1_000_000; // (an absorb that lasts)
            const health = creatureOf(w, caster).values.get!UNIT_FIELD_HEALTH;
            who.read();
            creatureCasts(w, caster, row[1], who);
            pass(w, who, 3.seconds);
            if (creatureOf(w, caster).values.get!UNIT_FIELD_HEALTH < health)
                ++back;
        }
        assert(back >= 3 && back <= 30, format!"%s: reflected %s of 60"(ward, back));
        // Without the talent: none.
        unlearn(who, row[0]);
        me.player.spells = me.player.spells[0 .. 1];
        back = 0;
        foreach (_; 0 .. 30)
        {
            const health = creatureOf(w, caster).values.get!UNIT_FIELD_HEALTH;
            creatureCasts(w, caster, row[1], who);
            pass(w, who, 3.seconds);
            if (creatureOf(w, caster).values.get!UNIT_FIELD_HEALTH < health)
                ++back;
        }
        assert(back == 0, "none without the talent");
    }
}

/// Frost Nova (10230): "Damage caused may interrupt the effect": a Fire Blast frees its target.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1055, "Novaer", mage, 60, [10230, 10199]);
    const kobold = toughEnemy(w, who, 5);
    novaUntilFrozen(w, who, kobold);
    assert(auraOn(w, kobold, 10230) !is null, "frozen");
    foreach (_; 0 .. 5) // (until a Fire Blast lands)
    {
        w.now += 9.seconds;
        topUp(who);
        who.read();
        assert(w.castAt(who, 10199, kobold) == SpellCastResult.ok);
        if (spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG).canFind!(l => l[0] == 10199 && l[1]))
            break;
    }
    assert(auraOn(w, kobold, 10230) is null, "free again");
}

/// Burning Soul rank 2 (12351): fire spells' threat 30% less; Arcane Subtlety rank 2 (12592): arcane's 40% less and
/// the target's resistances 10 less.
unittest
{
    import std.math : isClose;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1056, "Subtle", mage, 60, [10199, 10202]);
    auto me = who.session.inWorld;
    learn(w, who, 12351);
    learn(w, who, 12592);
    foreach (spell, factor; [10199u: 0.7f, 10202u: 0.6f])
    {
        const target = toughEnemy(w, who, spell == 10199 ? 10 : 3);
        who.read();
        topUp(who);
        w.now += 9.seconds;
        assert(w.castAt(who, spell, target) == SpellCastResult.ok);
        uint dealt;
        foreach (l; spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
            if (l[0] == spell)
                dealt += l[1];
        assert(dealt);
        const threat = creatureOf(w, target).ai.threatOf(me.player.guid);
        assert(isClose(threat, dealt * factor, 0.01), format!"%s: threat %s of %s"(spell, threat, dealt));
    }
    assert(me.targetResistance(50, 4) == 40, "10 less resistance");
}

/// Arcane Mind (2% a rank) more mana; Arcane Resilience (28574) armor of half the intellect.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1057, "Minded", mage, 60, []);
    auto me = who.session.inWorld;
    const mana = me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana);
    learn(w, who, 12503);
    const more = me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana);
    assert(more >= mana * 109 / 100 && more <= mana * 111 / 100, format!"%s to %s: 10%% more"(mana, more));
    const armor = me.player.values.get!UNIT_FIELD_RESISTANCES(0);
    learn(w, who, 28574);
    const intellect = me.player.values.get!UNIT_FIELD_STAT0(3);
    const diff = cast(int) me.player.values.get!UNIT_FIELD_RESISTANCES(0) - cast(int) armor;
    assert(diff >= cast(int) intellect / 2 - 1 && diff <= cast(int) intellect / 2 + 1, format!"%s armor of %s"(diff,
        intellect));
}

// ---------------------------------------------------------------------------------------------------------------
// Priest
// ---------------------------------------------------------------------------------------------------------------

private enum : uint
{
    smite = 585, holyFire = 14914, heal = 2054, greaterHeal = 2060, lesserHeal = 2050, flashHeal = 2061,
    prayerOfHealing = 596, holyNova = 15237, renew = 139, fortitude = 1243, prayerOfFortitude = 21562,
    powerWordShield = 17, innerFire = 588, manaBurn = 8129, mindBlast = 8092, psychicScream = 8122,
    shadowWordPain = 589, fade = 586, mindFlay = 15407, devouringPlague = 19276, starshards = 19296,
    desperatePrayer = 19236, vampiricEmbrace = 15286, hexOfWeakness = 19281, mindSoothe = 453, mindControl = 605,
    silence = 15487, shackleUndead = 9484, dispelMagic = 527, shadowProtection = 976,
}

/// The priest's talents that modify spells: each rank, on the spells its tooltip names.
unittest
{
    if (!haveRealData())
        return;
    alias Op = SpellModOp;
    static immutable uint[] heals = [lesserHeal, heal, greaterHeal, flashHeal, prayerOfHealing];
    static immutable uint[] holy = [smite, holyFire, holyNova, desperatePrayer] ~ heals;
    static immutable uint[] shadowDamage = [mindBlast, mindFlay, shadowWordPain, devouringPlague];
    static immutable uint[] shadow = shadowDamage ~ [vampiricEmbrace, hexOfWeakness, mindSoothe, mindControl, silence,
        psychicScream];
    checkMods(priest, [
        ModRow("Darkness: Mind Blast, Devouring Plague", [15259, 15307, 15308, 15309, 15310], Op.allEffects, true,
            [2, 4, 6, 8, 10], [mindBlast, devouringPlague], 1000, [smite]),
        ModRow("Darkness: over time", [15259, 15307, 15308, 15309, 15310], Op.dot, true, [2, 4, 6, 8, 10],
            [mindFlay, shadowWordPain], 1000),
        ModRow("Divine Fury", [18530, 18531, 18533, 18534, 18535], Op.castingTime, false, [-100, -200, -300, -400,
            -500], [smite, holyFire, heal, greaterHeal], 3000, [flashHeal, mindBlast]),
        ModRow("Force of Will: crit", [18544, 18547, 18548, 18549, 18550], Op.critChance, false, [1, 2, 3, 4, 5],
            [smite, holyFire, holyNova, mindBlast, manaBurn], 0, [heal]),
        ModRow("Force of Will: damage", [18544, 18547, 18548, 18549, 18550], Op.damage, true, [1, 2, 3, 4, 5],
            [smite, holyFire, holyNova, mindBlast], 1000, [heal]),
        ModRow("Force of Will: over time", [18544, 18547, 18548, 18549, 18550], Op.dot, true, [1, 2, 3, 4, 5],
            [mindFlay, shadowWordPain, starshards], 1000),
        ModRow("Healing Focus", [14913, 15012], Op.notLoseCastingTime, true, [35, 70], heals, 100, [smite]),
        ModRow("Holy Reach: range", [27789, 27790], Op.range, true, [10, 20], [smite, holyFire], 30, [mindBlast]),
        ModRow("Holy Reach: radius", [27789, 27790], Op.radius, true, [10, 20], [prayerOfHealing, holyNova], 30),
        ModRow("Holy Specialization", [14889, 15008, 15009, 15010, 15011], Op.critChance, false, [1, 2, 3, 4, 5],
            holy, 0, [mindBlast]),
        ModRow("Improved Fade", [15274, 15311], Op.cooldown, false, [-3000, -6000], [fade], 30_000),
        ModRow("Improved Healing", [14912, 15013, 15014], Op.cost, true, [-5, -10, -15], [lesserHeal, heal,
            greaterHeal], 1000, [flashHeal]),
        ModRow("Improved Inner Fire", [14747, 14770, 14771], Op.allEffects, true, [10, 20, 30], [innerFire], 1000),
        ModRow("Improved Mana Burn", [14750, 14772], Op.castingTime, false, [-250, -500], [manaBurn], 3000),
        ModRow("Improved Mind Blast", [15273, 15312, 15313, 15314, 15316], Op.cooldown, false,
            [-500, -1000, -1500, -2000, -2500], [mindBlast], 8000),
        ModRow("Improved Power Word: Fortitude", [14749, 14767], Op.allEffects, true, [15, 30], [fortitude,
            prayerOfFortitude], 1000),
        ModRow("Improved Power Word: Shield", [14748, 14768, 14769], Op.allEffects, true, [5, 10, 15],
            [powerWordShield], 1000),
        ModRow("Improved Prayer of Healing", [14911, 15018], Op.cost, true, [-10, -20], [prayerOfHealing], 1000,
            [heal]),
        ModRow("Improved Psychic Scream", [15392, 15448], Op.cooldown, false, [-2000, -4000], [psychicScream],
            30_000),
        ModRow("Improved Renew", [14908, 15020, 17191], Op.allEffects, true, [5, 10, 15], [renew], 1000),
        ModRow("Improved Shadow Word: Pain", [15275, 15317], Op.duration, false, [3000, 6000], [shadowWordPain],
            18_000),
        ModRow("Improved Vampiric Embrace", [27839, 27840], Op.allEffects, false, [5, 10], [vampiricEmbrace], 20),
        ModRow("Inner Focus: cost", [14751], Op.cost, true, [-100], heals ~ [smite, holyFire, holyNova] ~ shadowDamage,
            1000), // (Desperate Prayer costs nothing)
        ModRow("Inner Focus: crit", [14751], Op.critChance, false, [25], [smite, holyFire, heal, greaterHeal,
            flashHeal, mindBlast], 0),
        ModRow("Mental Agility", [14520, 14780, 14781, 14782, 14783], Op.cost, true, [-2, -4, -6, -8, -10],
            [renew, fortitude, powerWordShield, shadowWordPain, innerFire, psychicScream, fade, dispelMagic,
            shadowProtection], 1000, [heal, smite, mindBlast]),
        ModRow("Searing Light", [14909, 15017], Op.damage, true, [5, 10], [smite, holyFire], 1000, [mindBlast]),
        ModRow("Searing Light: over time", [14909, 15017], Op.dot, true, [5, 10], [holyFire], 1000),
        ModRow("Shadow Affinity", [15318, 15272, 15320], Op.threat, true, [-8, -16, -25], shadow, 1000, [smite]),
        ModRow("Shadow Focus", [15260, 15327, 15328, 15329, 15330], Op.resistMissChance, false, [2, 4, 6, 8, 10],
            shadow, 0, [smite]),
        ModRow("Shadow Reach", [17322, 17323, 17325], Op.range, true, [6, 13, 20], shadowDamage, 30, [smite]),
        ModRow("Spiritual Healing", [14898, 15349, 15354, 15355, 15356], Op.allEffects, true, [2, 4, 6, 8, 10],
            heals ~ [renew, desperatePrayer], 1000, [smite]),
        ModRow("Focused Casting", [14743, 27828], Op.notLoseCastingTime, true, [100, 100], heals ~ [smite, holyFire,
            mindBlast, mindFlay, manaBurn], 100),
    ]);
}

/// Aftermath (2% a rank): a Destruction spell (Shadow Bolt) dazes its target (18118: 50% slower) for 5 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    assertChances(w, "Aftermath", [18119, 18120, 18121, 18122, 18123], [2, 4, 6, 8, 10]);
    auto who = w.character(1101, "Dazer", warlock, 60, [686]);
    learn(w, who, 18123);
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 150)
    {
        topUp(who);
        w.castAt(who, 686, target);
        pass(w, who, 2.seconds);
        if (auto daze = auraOn(w, target, 18118))
        {
            assert(daze.maxDuration == 5000 && daze.amount[0] == -50);
            return;
        }
    }
    assert(false, "never dazed");
}

/**
 * Improved Shadow Bolt (4% a rank): a Shadow Bolt crit leaves Shadow Vulnerability (17794 ... 17800: 4% ... 20% more
 * shadow damage taken) for 4 damaging hits at most.
 */
unittest
{
    import std.math : isClose;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (k, rank; [17793u, 17796, 17801, 17802, 17803])
    {
        const vulnerability = spellOf(w, rank).triggerSpell[0];
        assert(rolls(w, vulnerability, 0)[0] == 4 * (k + 1), format!"rank %s: %s%%"(k + 1, 4 * (k + 1)));
    }
    auto who = w.character(1102, "Crit", warlock, 60, [686, 5676]);
    learn(w, who, 17803);
    giveAura(w, who, 23434, 100); // every spell a crit
    const target = toughEnemy(w, who, 10);
    foreach (_; 0 .. 5)
    {
        if (auraOn(w, target, 17800) !is null)
            break;
        topUp(who);
        w.castAt(who, 686, target);
        pass(w, who, 3.seconds);
    }
    auto vulnerable = auraOn(w, target, 17800);
    assert(vulnerable !is null && vulnerable.charges == 4, "4 hits");
    assert(isClose(creatureOf(w, target).fighter.damageTaken[5], 1.2f, 0.001), "20% more shadow damage");
    foreach (_; 0 .. 12)
    {
        if (auraOn(w, target, 17800) is null)
            break;
        topUp(who);
        w.castAt(who, 5676, target); // Searing Pain: a hit of another school spends a charge too
        pass(w, who, 2.seconds);
    }
    assert(auraOn(w, target, 17800) is null, "spent by the fourth");
}

/// Pyroclasm (13%, 26%): Rain of Fire's (5740) ticks stun (18093) for 3 sec.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1103, "Pyroclast", warlock, 60, [5740]);
    learn(w, who, 18073);
    const kobold = toughEnemy(w, who, 10);
    foreach (_; 0 .. 12)
    {
        w.now += 2.seconds;
        topUp(who);
        assert(castAtSpot(w, who, 5740, kobold) == SpellCastResult.ok);
        foreach (second; 0 .. 9)
        {
            pass(w, who, 1.seconds);
            if (auto stun = auraOn(w, kobold, 18093))
            {
                assert(stun.maxDuration == 3000);
                return;
            }
        }
    }
    assert(false, "never stunned");
}

/// Improved Drain Mana rank 2 (18393): 30% of the mana Drain Mana (5138) drains damages its target.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1104, "Drainer", warlock, 60, [5138]);
    learn(w, who, 18393);
    const target = toughEnemy(w, who, 10);
    auto c = creatureOf(w, target);
    c.values.setByte!UNIT_FIELD_BYTES_0(3, cast(ubyte) Power.mana); // (a kobold of mana)
    c.values.set!UNIT_FIELD_MAXPOWER1(Power.mana, 100_000u);
    c.values.set!UNIT_FIELD_POWER1(Power.mana, 100_000u);
    who.read();
    assert(w.castAt(who, 5138, target) == SpellCastResult.ok);
    pass(w, who, 1500.msecs);
    const drained = 100_000 - c.values.get!UNIT_FIELD_POWER1(Power.mana);
    assert(drained > 0, "drained");
    const hurt = spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG);
    assert(hurt.canFind!(l => l[0] == 5138 && l[1] == drained * 30 / 100), format!"30%% of %s: %s"(drained, hurt));
}

/**
 * Drain Soul (1120): its target dying under it gives a Soul Shard; with Improved Drain Soul rank 2 (18372: 100%)
 * Soul Siphon too (18371: mana regeneration 100% more for 10 sec).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1105, "Soulsucker", warlock, 60, [1120]);
    auto me = who.session.inWorld;
    learn(w, who, 18372);
    const target = toughEnemy(w, who, 10);
    auto c = creatureOf(w, target);
    c.values.set!UNIT_FIELD_LEVEL(60u); // (not grey to the warlock)
    c.values.set!UNIT_FIELD_HEALTH(5u);
    foreach (_; 0 .. 5) // (a drain may miss)
        if (c.alive)
        {
            topUp(who);
            w.castAt(who, 1120, target);
            pass(w, who, 4.seconds);
        }
    assert(!c.alive, "drained to death");
    assert(me.player.inventory.count(6265) == 1, "a Soul Shard");
    auto siphon = me.player.auras.find(18371);
    assert(siphon !is null && siphon.maxDuration == 10_000, "Soul Siphon");
}

/// Life Tap rank 6 (11689) with Plagueheart's set bonus (28830): the health cost 12% less, the mana as much.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1106, "Tapper", warlock, 60, [11689]);
    auto me = who.session.inWorld;
    giveAura(w, who, 28830);
    me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 0u);
    const health = me.player.values.get!UNIT_FIELD_HEALTH;
    assert(w.cast_(who, 11689) == SpellCastResult.ok);
    const lost = health - me.player.values.get!UNIT_FIELD_HEALTH;
    const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
    // (420 and the spell power's share: the mana as much, the health 12% less)
    assert(mana >= 420 && lost == cast(uint)(mana * 0.88f), format!"%s health for %s mana"(lost, mana));
}

/// Nightfall (2%, 4%) gives Shadow Trance (17941): the next Shadow Bolt (686) instant, and it goes with it.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    assertChances(w, "Nightfall", [18094, 18095], [2, 4]);
    auto who = w.character(1107, "Tranced", warlock, 60, [686]);
    auto me = who.session.inWorld;
    giveAura(w, who, 17941);
    const target = toughEnemy(w, who, 10);
    who.read();
    assert(w.castAt(who, 686, target) == SpellCastResult.ok);
    assert(startedCastTime(who, 686) == 0, "instant");
    assert(me.player.auras.find(17941) is null, "spent");
}

/// Amplify Curse (18288): the next Curse of Agony (980) half again as strong, and it goes with it.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1108, "Amplifier", warlock, 60, [980, 18288]);
    auto me = who.session.inWorld;
    assert(w.cast_(who, 18288) == SpellCastResult.ok);
    const target = toughEnemy(w, who, 10);
    w.now += 2.seconds;
    assert(w.castAt(who, 980, target) == SpellCastResult.ok);
    assert(me.player.auras.find(18288) is null, "spent");
    auto agony = auraOn(w, target, 980);
    assert(agony !is null && agony.amount[0] == rolls(w, 980, 0)[0] * 3 / 2, "half again");
}

/// Fear (5782) and Howl of Terror (5484): "Damage caused may interrupt the effect".
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(1109, "Terror", warlock, 60, [5782, 5484, 5676]);
    foreach (fear; [5782u, 5484])
    {
        const target = toughEnemy(w, who, 5);
        foreach (_; 0 .. 5)
            if (auraOn(w, target, fear) is null)
            {
                w.now += 41.seconds;
                topUp(who);
                fear == 5782 ? w.castAt(who, fear, target) : w.cast_(who, fear);
                pass(w, who, 2500.msecs);
            }
        assert(auraOn(w, target, fear) !is null, "afraid");
        foreach (_; 0 .. 5)
            if (auraOn(w, target, fear) !is null)
            {
                topUp(who);
                w.castAt(who, 5676, target);
                pass(w, who, 2.seconds);
            }
        assert(auraOn(w, target, fear) is null, "the damage ended it");
    }
}

/**
 * Create Healthstone (6201, 6202, 5699, 11729, 11730): the stone of its size; with Improved Healthstone (10%, 20%)
 * the one that heals that much more (Minor: 100, 110, 120).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    // The spells, and the stones.
    static immutable uint[4][] stones = [[6201, 5512, 19004, 19005], [6202, 5511, 19006, 19007],
        [5699, 5509, 19008, 19009], [11729, 5510, 19010, 19011], [11730, 9421, 19012, 19013]];
    foreach (k, talent; [0u, 18692, 18693])
    {
        auto who = w.character(cast(uint)(1110 + k), format!"Stoner%s"(k), warlock, 60, [6201, 6202, 5699, 11729,
            11730]);
        auto me = who.session.inWorld;
        if (talent)
            learn(w, who, talent);
        foreach (ref row; stones)
        {
            topUp(who);
            me.storeLoot(6265, 1, 0, false); // a Soul Shard, its reagent
            w.now += 2.seconds;
            const r = w.cast_(who, row[0]);
            assert(r == SpellCastResult.ok, format!"%s: %s"(row[0], r));
            pass(w, who, 4.seconds); // (its cast time)
            assert(me.player.inventory.count(row[1 + k]) == 1, format!"%s: the stone %s"(row[0], row[1 + k]));
        }
    }
    // What each heals: its own spell's (the improved Minor ones 110, 120).
    import dmangos.world.spellcast : effectValue;

    assert(rolls(w, 23468, 0)[0] == 110 && rolls(w, 23469, 0)[0] == 120 && rolls(w, 6262, 0)[0] == 100);
}
