/**
 * The class abilities (`dmangos.world.classspells`, `dmangos.world.procs`, `dmangos.scripts.spells`) tested on the
 * real data (`dmangos.world.realspelltests`): the spells as the client's DBC files and the world database have them,
 * cast by characters of their class. Each test here names what a test with invented fields missed.
 */
module dmangos.world.realclassspelltests;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind;
import dmangos.bytes : ByteReader;
import dmangos.world.auras : makeAura;
import dmangos.world.creature : Creature;
import dmangos.world.defines : PlayerClass, Power;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : SpellCastResult;
import dmangos.world.testclient;
import dmangos.world.updatefields;

/// The spell logs of `opcode` (damage, heal, energize: each a target, a caster, the spell, then its amount; an
/// energize's power first) since the last read: spell and the number after it.
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

/// Time passes: for the character and its map.
private void pass(ref RealWorld w, ref TestClient who, Duration elapsed)
{
    w.now += elapsed;
    who.session.inWorld.update(elapsed);
    w.context.map(0).update(elapsed);
}

/// The creature of `guid` on the map.
private Creature creatureOf(ref RealWorld w, ulong guid)
{
    return cast(Creature) w.context.map(0).findObject(guid);
}

/// An aura of the real spell `id` on the character, as its caster's (`stacks` times).
private void giveAura(ref RealWorld w, ref TestClient who, uint id, int amount = 0, uint stacks = 1)
{
    auto me = who.session.inWorld;
    foreach (_; 0 .. stacks)
        me.addAura(makeAura(w.context.data.spells.spell(id), me.player.guid, 60, -1, true, [amount, 0, 0]));
}

/// Ice Barrier (11426) and Frost Ward (6143) share every frost spell's flag (0x80000) with Ice Armor (7302): they are
/// no armor, and do not put it out; Mage Armor (6117) does.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto mage = w.character(11, "Khadgar", PlayerClass.mage, 60, [7302, 11426, 6143, 6117]);
    auto me = mage.session.inWorld;
    foreach (spell; [7302u, 11426u, 6143u])
    {
        assert(w.cast_(mage, spell) == SpellCastResult.ok);
        w.now += 2.seconds;
    }
    assert(me.player.auras.find(7302) !is null, "Ice Armor stays");
    assert(me.player.auras.find(11426) !is null && me.player.auras.find(6143) !is null);
    assert(w.cast_(mage, 6117) == SpellCastResult.ok);
    assert(me.player.auras.find(7302) is null, "Mage Armor puts Ice Armor out");
}

/// Judgement of Command (20425) strikes with 20467 (of no family): half, the target not stunned.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto paladin = w.character(12, "Uther", PlayerClass.paladin, 60, [20375, 20271]);
    auto me = paladin.session.inWorld;
    me.player.movement.position.orientation = 0; // facing east, where the enemy stands
    uint[] damage;
    foreach (attempt; 0 .. 12)
    {
        const hogger = w.enemy(paladin, 448);
        assert(w.cast_(paladin, 20375) == SpellCastResult.ok);
        w.now += 2.seconds;
        paladin.read();
        w.castAt(paladin, 20271, hogger);
        foreach (l; spellLogs(paladin, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
            if (l[0] == 20467 && l[1])
                damage ~= l[1];
        w.now += 11.seconds; // Judgement's cooldown
    }
    assert(damage.length, "judged");
    // 93 to 101, 5.6 more a level from 20 to 28: 137 to 145; half, 68 to 72 (a crit twice that).
    assert(damage.canFind!(d => d <= 72), "half: the target not stunned");
}

/// Illumination (rank 5, 20215: its trigger spell is 18350, a Dummy Trigger) gives a crit heal's mana back by 20272.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto paladin = w.character(13, "Turalyon", PlayerClass.paladin, 60, [20473]);
    auto me = paladin.session.inWorld;
    giveAura(w, paladin, 20215);
    giveAura(w, paladin, 23434, 50); // Increased Critical Spell: half its heals crit
    bool manaBack;
    foreach (attempt; 0 .. 60)
    {
        me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 1000u);
        w.now += 31.seconds; // Holy Shock's cooldown
        paladin.read();
        assert(w.cast_(paladin, 20473) == SpellCastResult.ok);
        if (spellLogs(paladin, Opcode.SMSG_SPELLENERGIZELOG).canFind!(l => l[0] == 20272 && l[1] == Power.mana))
        {
            manaBack = true;
            break;
        }
    }
    assert(manaBack, "Holy Shock's mana back at a crit");
}

/// Healing Way (29203: 6% a stack, three at most) adds to Healing Wave (331) by its stacks: 18%.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto shaman = w.character(14, "Thrall", PlayerClass.paladin, 60, [331]); // (a human: a paladin who knows it)
    auto me = shaman.session.inWorld;
    giveAura(w, shaman, 29203, 6, 3);
    assert(me.player.auras.find(29203).stacks == 3);
    // Rank 1's 36 to 47 (33, 0.7 a level to level 5, and a die of 11), a crit half again: 18% more, never 6%.
    bool fits(uint healed, int percent)
    {
        foreach (base; 35u .. 48u)
            if (healed == base * (100 + percent) / 100 || healed == base * (100 + percent) / 100 * 3 / 2)
                return true;
        return false;
    }
    uint[] heals;
    foreach (attempt; 0 .. 15)
    {
        me.player.values.set!UNIT_FIELD_HEALTH(100u);
        me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 1000u);
        shaman.read();
        assert(w.cast_(shaman, 331) == SpellCastResult.ok);
        pass(w, shaman, 2000.msecs); // its cast time
        foreach (l; spellLogs(shaman, Opcode.SMSG_SPELLHEALLOG))
            if (l[0] == 331)
                heals ~= l[1];
    }
    assert(heals.length == 15);
    import std.algorithm.searching : all, any;
    import std.format : format; assert(heals.all!(h => fits(h, 18)) && heals.any!(h => !fits(h, 6)), format!"18%% more %s"(heals));
}

/// Mana Shield (1463) absorbs half the arcane spell power more: each of Unstable Power's stacks (24659: 17).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto mage = w.character(15, "Rhonin", PlayerClass.mage, 60, [1463]);
    auto me = mage.session.inWorld;
    assert(w.cast_(mage, 1463) == SpellCastResult.ok);
    const plain = me.player.auras.find(1463).amount[0];
    me.removeAura(me.player.auras.find(1463));
    giveAura(w, mage, 24659, 17, 3);
    w.now += 2.seconds;
    assert(w.cast_(mage, 1463) == SpellCastResult.ok);
    assert(me.player.auras.find(1463).amount[0] == plain + 51 / 2, "half of three stacks' 51");
}

/**
 * Seal of Righteousness, rank 1 (20154, learned at level 1), on a swing without a weapon: its holy damage (25742) is of
 * the weapon's own damage (a fist's 1 to 2), not the attack power's; and a level 1 spell's share of the spell power
 * (0.2875: `CalculateLevelPenalty`), of each of Unstable Power's six stacks.
 */
unittest
{
    import dmangos.world.combat : AttackType;
    import dmangos.world.defines : equipmentSlotMainhand;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto paladin = w.character(16, "Tirion", PlayerClass.paladin, 60, [20154]);
    auto me = paladin.session.inWorld;
    assert(me.player.inventory.equipped(equipmentSlotMainhand) is null, "(the test swings bare-handed)");
    me.player.movement.position.orientation = 0;
    giveAura(w, paladin, 24659, 17, 6);
    const seal = w.context.data.spells.spell(20154);
    // Its 108 and 18 a level to level 7: 216. 0.85 * ceil(216 * 1.2 * 1.03 * 2.0 / 100) - 1 = 4.1; 0.03 of the fist's
    // 1.5; 1; and 102 * 0.092 * 2.0 * 0.2875.
    const expected = cast(int)(4.1f + 0.045f) + 1 + cast(int)(102 * 0.092f * 2.0f * 0.2875f);
    const hogger = w.enemy(paladin, 448);
    uint[] struck;
    foreach (attempt; 0 .. 60)
    {
        if (me.player.auras.find(20154) is null)
            assert(w.cast_(paladin, 20154) == SpellCastResult.ok);
        // What the attack power makes of a swing, which the seal does not take.
        me.player.values.set!UNIT_FIELD_MINDAMAGE(300.0f);
        me.player.values.set!UNIT_FIELD_MAXDAMAGE(400.0f);
        paladin.read();
        me.swing(creatureOf(w, hogger), AttackType.mainHand);
        foreach (l; spellLogs(paladin, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
            if (l[0] == 25742)
                struck ~= l[1];
        if (struck.length)
            break;
        w.now += 2.seconds;
    }
    assert(struck.length, "a swing lands");
    // (and what every holy spell gets of the spell power besides, 1.5 / 3.5 of one stack's 17 or of all six's 102, if
    // anything: CMaNGOS's spell_bonus_data gives 25742 none)
    assert(seal.spellLevel == 1 && [expected, expected + 7, expected + 43].canFind(struck[0]), "of the fist, a level 1 share");
}

/// Judgement of Wisdom (20186: proc flags 139944) gives mana to who strikes its target with a spell too (Fire Blast).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto mage = w.character(17, "Modera", PlayerClass.mage, 60, [2136]);
    auto me = mage.session.inWorld;
    me.player.movement.position.orientation = 0;
    bool mana;
    foreach (attempt; 0 .. 30)
    {
        const hogger = w.enemy(mage, 448);
        bool isNew;
        auto target = creatureOf(w, hogger);
        target.auras.apply(makeAura(w.context.data.spells.spell(20186), 99, 60, 10_000, false, [0, 0, 0]),
            target.values, isNew);
        mage.read();
        w.castAt(mage, 2136, hogger);
        if (spellLogs(mage, Opcode.SMSG_SPELLENERGIZELOG).canFind!(l => l[0] == 20268))
        {
            mana = true;
            break;
        }
        w.now += 9.seconds; // Fire Blast's cooldown
    }
    assert(mana, "20268's mana, half the time");
}

/// Vampiric Embrace (15286: proc flags 655360, a periodic tick's among them) heals by Shadow Word: Pain's ticks (589).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto priest = w.character(18, "Benedictus", PlayerClass.priest, 60, [15286, 589]);
    auto me = priest.session.inWorld;
    me.player.movement.position.orientation = 0;
    const hogger = w.enemy(priest, 448);
    assert(w.castAt(priest, 15286, hogger) == SpellCastResult.ok);
    w.now += 2.seconds;
    assert(w.castAt(priest, 589, hogger) == SpellCastResult.ok);
    priest.read();
    me.player.values.set!UNIT_FIELD_HEALTH(100u);
    foreach (_; 0 .. 7)
        pass(w, priest, 1000.msecs);
    assert(spellLogs(priest, Opcode.SMSG_SPELLHEALLOG).canFind!(l => l[0] == 15290), "healed by its ticks");
}

/// Nightfall (18095: 4%, on Corruption's and Drain Life's ticks) by Drain Life's (689: a leech) ticks: Shadow Trance.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto warlock = w.character(19, "Kanrethad", PlayerClass.warlock, 60, [689]);
    auto me = warlock.session.inWorld;
    me.player.movement.position.orientation = 0;
    giveAura(w, warlock, 18095);
    const hogger = w.enemy(warlock, 448);
    auto target = creatureOf(w, hogger);
    const drain = w.context.data.spells.spell(689);
    bool trance;
    foreach (attempt; 0 .. 120)
    {
        // Its drain on the creature, as a cast leaves it (a channel the creature's blows would cut short).
        bool isNew;
        target.auras.apply(makeAura(drain, me.player.guid, 60, 5000, false, [10, 0, 0]), target.values, isNew);
        target.values.set!UNIT_FIELD_HEALTH(target.values.get!UNIT_FIELD_MAXHEALTH);
        me.player.values.set!UNIT_FIELD_HEALTH(me.player.values.get!UNIT_FIELD_MAXHEALTH);
        foreach (_; 0 .. 6)
            pass(w, warlock, 1000.msecs);
        if (me.player.auras.find(17941) !is null)
        {
            trance = true;
            break;
        }
    }
    assert(trance, "Shadow Trance from a Drain Life tick");
}

/// Retaliation (20230) strikes back with the warrior's own spell, 20240 (22858 is a creature's), at a swing from in front.
unittest
{
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.unit : Blow, dealDamage;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto warrior = w.character(20, "Varok", PlayerClass.warrior, 60, [2457, 20230]);
    auto me = warrior.session.inWorld;
    me.player.movement.position.orientation = 0;
    const hogger = w.enemy(warrior, 448);
    assert(w.cast_(warrior, 2457) == SpellCastResult.ok); // Battle Stance, which it needs
    w.now += 2.seconds;
    import std.format : format;
    const r = w.cast_(warrior, 20230);
    assert(r == SpellCastResult.ok, format!"Retaliation: %s"(r));
    warrior.read();
    MeleeDamage d;
    d.attacker = hogger;
    d.target = me.player.guid;
    d.outcome = MeleeHitOutcome.normal;
    d.damage = 5;
    dealDamage(w.context.map(0).unit(hogger), me.unit, 5, Blow.swing(d));
    assert(spellLogs(warrior, Opcode.SMSG_SPELLNONMELEEDAMAGELOG).canFind!(l => l[0] == 20240), "struck back by 20240");
}

/**
 * Lightning Shield (324: three charges) strikes back once in three seconds at most: spell_proc_event's cooldown, 3,
 * is in seconds (this database's CMaNGOS read it so; 22648's is 120).
 */
unittest
{
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.unit : Blow, dealDamage;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto shaman = w.character(21, "Drekthar", PlayerClass.paladin, 60, [324]); // (a human: a paladin who knows it)
    auto me = shaman.session.inWorld;
    me.player.movement.position.orientation = 0;
    const hogger = w.enemy(shaman, 448);
    assert(w.cast_(shaman, 324) == SpellCastResult.ok);
    void struck()
    {
        MeleeDamage d;
        d.attacker = hogger;
        d.target = me.player.guid;
        d.outcome = MeleeHitOutcome.normal;
        d.damage = 5;
        dealDamage(w.context.map(0).unit(hogger), me.unit, 5, Blow.swing(d));
    }
    struck();
    assert(me.player.auras.find(324).charges == 2, "a charge spent");
    w.now += 1.seconds;
    struck();
    assert(me.player.auras.find(324).charges == 2, "not again within three seconds");
    w.now += 3.seconds;
    struck();
    assert(me.player.auras.find(324).charges == 1, "three seconds on, again");
}

/// Improved Life Tap's second rank (18183: 20%) adds to Life Tap's mana as its first does: spell_affect names only the
/// first (18182), for every rank.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto warlock = w.character(22, "Gul'dan", PlayerClass.warlock, 60, [1454]);
    auto me = warlock.session.inWorld;
    giveAura(w, warlock, 18183, 20);
    me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 0u);
    const health = me.player.values.get!UNIT_FIELD_HEALTH;
    assert(w.cast_(warlock, 1454) == SpellCastResult.ok);
    const lost = health - me.player.values.get!UNIT_FIELD_HEALTH;
    assert(lost > 0 && me.player.values.get!UNIT_FIELD_POWER1(Power.mana) == lost * 120 / 100, "a fifth more mana");
}

/// Curse of Agony (980: 7 a tick, twelve ticks) deals its 84 whole: the last four ticks round up what the first lost.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto warlock = w.character(23, "Ner'zhul", PlayerClass.warlock, 60, [980]);
    auto me = warlock.session.inWorld;
    me.player.movement.position.orientation = 0;
    const hogger = w.enemy(warlock, 448);
    auto target = creatureOf(w, hogger);
    const before = target.values.get!UNIT_FIELD_HEALTH;
    assert(w.castAt(warlock, 980, hogger) == SpellCastResult.ok);
    foreach (_; 0 .. 26)
        pass(w, warlock, 1000.msecs);
    assert(target.auras.find(980) is null, "run out");
    assert(before - target.values.get!UNIT_FIELD_HEALTH == 84, "3, 7 and 11 four times each");
}

/// Preparation (14185) makes Evasion (5277) ready again: its cooldown is its category's (66), not its own.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto rogue = w.character(24, "Garona", PlayerClass.rogue, 60, [5277, 14185]);
    auto me = rogue.session.inWorld;
    assert(w.cast_(rogue, 5277) == SpellCastResult.ok);
    assert(!me.spellIsReady(5277));
    w.now += 2.seconds;
    assert(w.cast_(rogue, 14185) == SpellCastResult.ok);
    assert(me.spellIsReady(5277), "Evasion ready");
}

/// Enrage (5229) in Dire Bear Form (9634) takes 16% of the armor, not Bear Form's 27%: on 25503's second effect, the
/// armor one (its first is none).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto druid = w.character(25, "Malfurion", PlayerClass.paladin, 60, [9634, 5229]); // (a human: a paladin who knows them)
    auto me = druid.session.inWorld;
    import std.format : format;
    const r = w.cast_(druid, 9634);
    assert(r == SpellCastResult.ok, format!"Dire Bear Form: %s"(r));
    w.now += 2.seconds;
    const e = w.cast_(druid, 5229);
    assert(e == SpellCastResult.ok, format!"Enrage: %s"(e));
    auto armor = me.player.auras.find(25503);
    assert(armor !is null && armor.amount[1] == -16, "16% less armor");
}
