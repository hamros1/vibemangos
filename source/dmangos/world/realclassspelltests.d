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

/// Mana Shield (1463) absorbs the same however much spell power (Unstable Power's stacks, 24659: 17): Blizzard's
/// coefficient for it is none.
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
    assert(me.player.auras.find(1463).amount[0] == plain, "no spell power");
}

/**
 * Seal of Righteousness, rank 1 (20154, learned at level 1), on a swing without a weapon: its holy damage (25742) is by
 * the fist's speed (2.0), not the attack power's damage; and Blizzard's coefficient of 25742 (0.029: 0.1
 * less the level 1 penalty) of the spell power, each of Unstable Power's six stacks' (102), once.
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
    // Its 108 and 18 a level to level 7: 216, by the speed in hundredths (the tooltip's): 216 * 2.0 / 100 = 4.3; and
    // 102 * 0.029.
    const expected = cast(int)(216 * 2.0f / 100) + cast(int)(102 * 0.029f);
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
    import std.format : format;
    assert(seal.spellLevel == 1 && struck[0] == expected, format!"of the fist, a level 1 share: %s, not %s"(struck[0], expected));
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

/// `creature_spawn_data`: the Plague Spreaders of spawns 5237 .. 5239 (604) are of faction 43, not their template's;
/// spawn 6150 (848) runs as it comes (`SPAWN_FLAG_RUN_ON_SPAWN`); a spawn without data (Hogger's) is its template's.
unittest
{
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : MovementFlags;
    import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    Creature spawned(uint entry, uint guid, float x, float y)
    {
        foreach (ref spawn; w.context.data.creatureSpawns)
            if (spawn.guid == guid)
                return w.context.makeCreature(&spawn);
        return null;
    }
    auto spreader = spawned(604, 5237, -11256.5f, -358.5f);
    assert(spreader !is null && spreader.values.get!UNIT_FIELD_FACTIONTEMPLATE == 43
        && w.context.data.creatureTemplates[604].faction != 43, "the Plague Spreader's faction of its spawn");
    auto runner = spawned(848, 6150, -9327.6f, -2202.1f);
    assert(runner !is null && !runner.movement.has(MovementFlags.walkMode), "spawn 6150 runs");
}

/// `item_required_target`: the Wildkin Muisek Vessel (9618) only at a slain owlbeast (2927, type 2: dead), not a live
/// one nor Hogger (448); a Hearthstone (6948), named by no row, at anything.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(20, "Muisek", PlayerClass.hunter, 60, [], 3);
    auto me = who.session.inWorld;
    const owlbeast = w.enemy(who, 2927), hogger = w.enemy(who, 448);
    assert(!me.itemTargetAllowed(9618, owlbeast), "not at a live owlbeast");
    assert(!me.itemTargetAllowed(9618, hogger) && !me.itemTargetAllowed(9618, 0), "nor at another, nor at none");
    assert(me.itemTargetAllowed(6948, hogger) && me.itemTargetAllowed(6948, 0), "an item no row names: anything");
    creatureOf(w, owlbeast).values.set!(imported!"dmangos.world.updatefields".UNIT_FIELD_HEALTH)(0u); // slain
    assert(me.itemTargetAllowed(9618, owlbeast), "at a slain one");
}

/// A creature's immunity set (`creature_immunities`, set 0): Sneed's Shredder (642) takes no taunt (effect 114,
/// `MOD_TAUNT`), the Shade of Eranikus (5709) no slowing of its casts nor of its legs (auras 216, 33); Hogger (448),
/// without a set, both.
unittest
{
    import dmangos.world.spellids : AuraType, SpellEffect;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(19, "Immune", PlayerClass.warrior, 60, []);
    const shredder = creatureOf(w, w.enemy(who, 642)).fighter.immune;
    assert(shredder.toEffect(SpellEffect.attackMe, 0, 0) && shredder.toEffect(SpellEffect.applyAura, 0, AuraType.modTaunt),
        "Sneed's Shredder: no taunt");
    const shade = creatureOf(w, w.enemy(who, 5709)).fighter.immune;
    assert(shade.toEffect(SpellEffect.applyAura, 0, 216) && shade.toEffect(SpellEffect.applyAura, 0, AuraType.modDecreaseSpeed),
        "the Shade of Eranikus: no slowing");
    const hogger = creatureOf(w, w.enemy(who, 448)).fighter.immune;
    assert(!hogger.toEffect(SpellEffect.attackMe, 0, 0) && !hogger.toEffect(SpellEffect.applyAura, 0, 216), "Hogger: none");
}

/// A relic's spell power for the spells its aura affects: Totem of Life's (27855: 80, `spell_affect` 128) for Lesser
/// Healing Wave (8004), not Healing Wave (331); Totem of Rage's (27859: 30, by its `EffectItemType`) for Earth Shock
/// (8042), not Lightning Bolt (403). None without it.
unittest
{
    import dmangos.world.caster : Caster;
    import dmangos.world.spelldamage : relicBonus;
    enum ubyte raceOrc = 2;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto shaman = w.character(18, "Thrall", PlayerClass.shaman, 60, [8004, 331, 8042, 403], raceOrc);
    auto me = shaman.session.inWorld;
    auto caster = Caster.of(me);
    const spells = w.context.data.spells;
    assert(relicBonus(caster, spells.spell(8004), true) == 0, "none without the relic");
    bool isNew;
    foreach (relic; [27855u, 27859u])
    {
        const s = spells.spell(relic);
        me.player.auras.apply(makeAura(s, me.player.guid, 60, -1, true, [s.basePoints[0] + 1, 0, 0]), me.player.values,
            isNew);
    }
    assert(relicBonus(caster, spells.spell(8004), true) == 80, "Lesser Healing Wave: Totem of Life's");
    assert(relicBonus(caster, spells.spell(331), true) == 0, "not Healing Wave");
    assert(relicBonus(caster, spells.spell(8042), false) == 30, "Earth Shock: Totem of Rage's");
    assert(relicBonus(caster, spells.spell(403), false) == 0, "not Lightning Bolt");
    assert(relicBonus(caster, spells.spell(8042), true) == 0, "and no healing for it");
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
    // Hurt, to be healed, though not to be slain by Hogger meanwhile (his Rushing Charge's +40 damage a blow).
    me.player.values.set!UNIT_FIELD_HEALTH(me.player.values.get!UNIT_FIELD_MAXHEALTH / 2);
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

/**
 * Spell power by Blizzard's coefficients (data/coefficients.csv): 100 spell damage (Arcane Might, 17150, as 100)
 * adds 81 to Frostbolt (25304: 0.814) and 16 to each tick of Shadow Word: Pain (10894: 0.167 a tick); 100 healing
 * (Increase Healing 2, 7675, as 100) 71 to Holy Light's heal (19968: 0.714) but 20 to rank 1's own (19982: 0.205).
 */
unittest
{
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    if (w.context.client.spellCoefficients.length == 0)
        return; // no data/coefficients.csv: the 1.12 formula, tested with invented spells
    auto priest = w.character(30, "Faol", PlayerClass.priest, 60, [10894]);
    auto me = priest.session.inWorld;
    giveAura(w, priest, 17150, 100);
    assert(me.spellDamageBonus(w.context.data.spells.spell(25304), 4) == 81, "Frostbolt: 0.814");
    const kobold = w.enemy(priest);
    me.player.movement.position.orientation = 0;
    assert(w.castAt(priest, 10894, kobold) == SpellCastResult.ok);
    const pain = creatureOf(w, kobold).auras.find(10894);
    assert(pain !is null, "Shadow Word: Pain on the kobold");
    // Rank 8's 142 a tick (its 141 + 1), 16 more by the power.
    import std.format : format;
    assert(pain.amount[0] == 142 + 16, format!"Shadow Word: Pain: 0.167 a tick: %s"(pain.amount[0]));

    auto paladin = w.character(31, "Alonsus", PlayerClass.paladin, 60, [635, 10329]);
    auto pal = paladin.session.inWorld;
    giveAura(w, paladin, 7675, 100);
    assert(pal.healingBonus(w.context.data.spells.spell(19968)) == 71, "Holy Light's heal: 0.714");
    assert(pal.healingBonus(w.context.data.spells.spell(19982)) == 20, "rank 1's own: 0.205");
    // Rank 1 heals by 19982 (rank 7 by 19968): what the heal log names.
    uint healedBy(uint rank)
    {
        pal.player.values.set!UNIT_FIELD_HEALTH(1u);
        w.now += 3.seconds;
        assert(w.cast_(paladin, rank) == SpellCastResult.ok);
        foreach (step; 0 .. 4)
        {
            w.now += 1.seconds;
            pal.update(1.seconds);
            w.context.map(0).update(1.seconds);
        }
        foreach (p; paladin.read())
            if (p.opcode == Opcode.SMSG_SPELLHEALLOG)
            {
                auto r = ByteReader(p.body_);
                r.readPackedGuid();
                r.readPackedGuid();
                return r.read!uint;
            }
        return 0;
    }
    assert(healedBy(635) == 19982, "rank 1's own heal");
    assert(healedBy(10329) == 19968, "rank 8's: the common one");
}

/**
 * Barkskin (22812) as its tooltip says, beyond its data (`dmangos.world.tooltipeffects`): "Physical damage taken is
 * reduced by 20%" and "melee combat is slowed by 25%"; no other school's damage less.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto druid = w.character(32, "Malfurion", PlayerClass.druid, 60, [22812], 4); // a night elf
    auto me = druid.session.inWorld;
    const swing = me.player.values.get!UNIT_FIELD_BASEATTACKTIME(0);
    assert(me.player.damageMods.taken[0] == 1.0f);
    assert(w.cast_(druid, 22812) == SpellCastResult.ok);
    assert(me.player.auras.find(22812) !is null, "barkskinned");
    import std.math : isClose;
    assert(me.player.damageMods.taken[0].isClose(0.8f), "physical: 20% less");
    assert(me.player.damageMods.taken[2] == 1.0f, "fire: as before");
    const slowed = me.player.values.get!UNIT_FIELD_BASEATTACKTIME(0);
    assert(slowed == cast(uint)(swing * 1.25f), "melee 25% slower");
    me.removeAura(me.player.auras.find(22812));
    assert(me.player.damageMods.taken[0] == 1.0f && me.player.values.get!UNIT_FIELD_BASEATTACKTIME(0) == swing, "and back");
}
