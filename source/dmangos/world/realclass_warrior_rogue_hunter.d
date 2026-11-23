/**
 * The warrior's, rogue's and hunter's spells beyond their basic effects (`dmangos.world.realspellsweep` checks
 * those), tested on the real data (`dmangos.world.realspelltests`): each talent and each spell docs/spells says needs
 * code, by what its 1.12.1 tooltip claims, for its ranks.
 */
module dmangos.world.realclass_warrior_rogue_hunter;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.bytes : ByteReader;
import dmangos.world.auras : Aura, makeAura;
import dmangos.world.combat : AttackType, MeleeDamage, MeleeHitOutcome;
import dmangos.world.creature : Creature;
import dmangos.world.defines : PlayerClass, Power;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : SpellCastResult;
import dmangos.world.spellmods : applySpellMod, SpellModOp;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient;
import dmangos.world.updatefields;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The spell logs of `opcode` (damage, heal, energize: a target, a caster, the spell, then its amount) since the
/// last read: spell and the number after it.
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

/// The real spell `id`.
private const(SpellInfo)* spellOf(ref RealWorld w, uint id)
{
    const s = w.context.data.spells.spell(id);
    assert(s !is null, format!"no spell %s"(id));
    return s;
}

/// An aura of the real spell `id` on the character, as its own (a talent bound to a weapon too).
private Aura giveAura(ref RealWorld w, ref TestClient who, uint id, int amount = int.min)
{
    import dmangos.world.spellcast : effectValue;

    auto me = who.session.inWorld;
    const spell = spellOf(w, id);
    int[3] values;
    foreach (i; 0 .. 3)
        values[i] = effectValue(*spell, i, 60, 0);
    if (amount != int.min)
        values[0] = amount;
    auto aura = makeAura(spell, me.player.guid, 60, -1, true, values);
    aura.passive = spell.isPassive;
    me.addAura(aura);
    return me.player.auras.find(id);
}

/// The talent (a rank of one) learned: its passive aura on.
private void talent(ref RealWorld w, ref TestClient who, uint id)
{
    auto me = who.session.inWorld;
    me.applyPassive(spellOf(w, id));
    if (me.player.auras.find(id) is null) // one bound to a weapon: on as if it were in hand
        giveAura(w, who, id);
    assert(me.player.auras.find(id) !is null, format!"talent %s on"(id));
}

/// The aura of `id` off the character.
private void drop(ref TestClient who, uint id)
{
    auto me = who.session.inWorld;
    while (auto aura = me.player.auras.find(id))
        me.removeAura(aura);
}

/// `who` takes the item `entry` and puts it on.
private void equip(ref TestClient who, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    auto me = who.session.inWorld;
    // Its weapon skills at a level 60's best (a new character's are 1: glancing blows, few crits; a rogue knows no sword).
    foreach (skill; [43u, 44, 54, 55, 160, 172, 173, 229, 45, 46, 226, 162, 95])
        me.player.setSkill(skill, 300, 300);
    me.player.refreshChances(me.context.data);
    me.storeLoot(entry, 1, 0, false);
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
            {
                import dmangos.world.packets : ClientSwapInvItem;

                // A melee weapon in the main hand (a rogue's starting dagger out of it, not into the off hand).
                const type = item.proto.inventoryType;
                if (item.proto.itemClass == 2 && (type == 13 || type == 17 || type == 21))
                    who.write(Opcode.CMSG_SWAP_INV_ITEM, ClientSwapInvItem(s, 15));
                else
                    who.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, s));
                break;
            }
    who.read();
}

/// A swing of the creature `attacker` at `who` that had `outcome`.
private void struck(ref RealWorld w, ref TestClient who, ulong attacker, MeleeHitOutcome outcome, uint damage = 5)
{
    import dmangos.world.combat : VictimState;
    import dmangos.world.unit : Blow, dealDamage;

    auto me = who.session.inWorld;
    MeleeDamage d;
    d.attacker = attacker;
    d.target = me.player.guid;
    d.outcome = outcome;
    d.damage = outcome == MeleeHitOutcome.miss || outcome == MeleeHitOutcome.dodge
        || outcome == MeleeHitOutcome.parry ? 0 : damage;
    d.targetState = outcome == MeleeHitOutcome.parry ? VictimState.parry : outcome == MeleeHitOutcome.dodge
        ? VictimState.dodge : VictimState.normal;
    dealDamage(w.context.map(0).unit(attacker), me.unit, d.damage, Blow.swing(d));
}

/// The character's power of `type` (rage in tenths), and set.
private uint power(ref TestClient who, Power type)
{
    return who.session.inWorld.player.values.get!UNIT_FIELD_POWER1(type);
}

private void setPower(ref TestClient who, Power type, uint value)
{
    who.session.inWorld.player.values.set!UNIT_FIELD_POWER1(type, value);
}

/// A creature of `entry` (a kobold) in front of `who`, its guid; `who` faces it.
private ulong foe(ref RealWorld w, ref TestClient who, uint entry = 6)
{
    who.session.inWorld.player.movement.position.orientation = 0; // facing east, where it stands
    const guid = w.enemy(who, entry);
    if (entry == 448) // Hogger: health enough for a level 60's finishers (none die of a test's blows)
    {
        auto c = creatureOf(w, guid);
        c.values.set!UNIT_FIELD_MAXHEALTH(1_000_000u);
        c.values.set!UNIT_FIELD_HEALTH(1_000_000u);
    }
    return guid;
}

/// Casts `spell` at `target` until it lands (a kobold may dodge): true if one did, by `landed`.
private bool castUntil(ref RealWorld w, ref TestClient who, uint spell, ulong target, bool delegate() landed,
    uint attempts = 30, Duration between = 2.seconds)
{
    foreach (_; 0 .. attempts)
    {
        w.now += between;
        w.castAt(who, spell, target);
        if (landed())
            return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The talents that change other spells (`SPELL_AURA_ADD_FLAT_MODIFIER`, `_PCT_MODIFIER`): each rank, its spell
// ---------------------------------------------------------------------------

/// A talent's ranks, a spell they change, the property, its value without them and with each rank (the tooltip's
/// numbers in the data's units: rage and its costs in tenths, times in milliseconds).
private struct ModRow
{
    string name;
    uint[] ranks;
    uint spell;
    SpellModOp op;
    int base;
    int[] expected;
}

private static immutable ModRow[] modTable = [
    // Warrior
    ModRow("Booming Voice: Battle Shout lasts 50% longer", [12321, 12835, 12836, 12837, 12838], 11551,
        SpellModOp.duration, 120_000, [132_000, 144_000, 156_000, 168_000, 180_000]),
    ModRow("Booming Voice: Demoralizing Shout's area 50% wider", [12321, 12835, 12836, 12837, 12838], 11556,
        SpellModOp.radius, 1000, [1100, 1200, 1300, 1400, 1500]),
    ModRow("Impale: 20% more crit damage bonus (Mortal Strike)", [16493, 16494], 21553, SpellModOp.critDamageBonus,
        100, [110, 120]),
    ModRow("Improved Battle Shout: 25% more attack power", [12318, 12857, 12858, 12860, 12861], 11551,
        SpellModOp.allEffects, 100, [105, 110, 115, 120, 125]),
    ModRow("Improved Bloodrage: 5 more instant rage", [12301, 12818], 2687, SpellModOp.allEffects, 100, [120, 150]),
    ModRow("Improved Charge: 6 more rage", [12285, 12697], 11578, SpellModOp.allEffects, 150, [180, 210]),
    ModRow("Improved Cleave: 120% more bonus damage", [12329, 12950, 20496], 20569, SpellModOp.allEffects, 100,
        [140, 180, 220]),
    ModRow("Improved Demoralizing Shout: 40% more reduction", [12324, 12876, 12877, 12878, 12879], 11556,
        SpellModOp.allEffects, 100, [108, 116, 124, 132, 140]),
    ModRow("Improved Disarm: 3 sec longer", [12313, 12804, 12807], 676, SpellModOp.duration, 10_000,
        [11_000, 12_000, 13_000]),
    ModRow("Improved Execute: 5 rage less", [20502, 20503], 20662, SpellModOp.cost, 150, [130, 100]),
    ModRow("Improved Heroic Strike: 3 rage less", [12282, 12663, 12664], 11567, SpellModOp.cost, 150, [140, 130, 120]),
    ModRow("Improved Intercept: 10 sec less cooldown", [20504, 20505], 20617, SpellModOp.cooldown, 30_000,
        [25_000, 20_000]),
    ModRow("Improved Overpower: 50% more crit chance", [12290, 12963], 11585, SpellModOp.critChance, 0, [25, 50]),
    ModRow("Improved Rend: 35% more bleed", [12286, 12658, 12659], 11574, SpellModOp.allEffects, 100, [115, 125, 135]),
    ModRow("Improved Shield Block: an attack more", [12945, 12307, 12944], 2565, SpellModOp.charges, 1, [2, 2, 2]),
    ModRow("Improved Shield Block: 2 sec longer", [12945, 12307, 12944], 2565, SpellModOp.duration, 5000,
        [5500, 6000, 7000]),
    ModRow("Improved Shield Wall: 5 sec longer", [12312, 12803], 871, SpellModOp.duration, 10_000, [13_000, 15_000]),
    ModRow("Improved Slam: 0.5 sec less casting time", [12862, 12330, 20497, 20498, 20499], 11605,
        SpellModOp.castingTime, 1500, [1400, 1300, 1200, 1100, 1000]),
    ModRow("Improved Sunder Armor: 3 rage less", [12308, 12810, 12811], 11597, SpellModOp.cost, 150, [140, 130, 120]),
    ModRow("Improved Taunt: 2 sec less cooldown", [12302, 12765], 355, SpellModOp.cooldown, 10_000, [9000, 8000]),
    ModRow("Improved Thunder Clap: 4 rage less", [12287, 12665, 12666], 11581, SpellModOp.cost, 200, [190, 180, 160]),
    // Rogue
    ModRow("Aggression: 6% more Sinister Strike damage", [18427, 18428, 18429], 11294, SpellModOp.damage, 1000,
        [1020, 1040, 1060]),
    ModRow("Aggression: 6% more Eviscerate damage", [18427, 18428, 18429], 11300, SpellModOp.damage, 1000,
        [1020, 1040, 1060]),
    ModRow("Camouflage: 15% more speed in Stealth", [13975, 14062, 14063, 14064, 14065], 1787, SpellModOp.effect2, 0,
        [3, 6, 9, 12, 15]),
    ModRow("Camouflage: 5 sec less Stealth cooldown", [13975, 14062, 14063, 14064, 14065], 1787, SpellModOp.cooldown,
        10_000, [9000, 8000, 7000, 6000, 5000]),
    ModRow("Cold Blood: 100% more crit chance (Sinister Strike)", [14177], 11294, SpellModOp.critChance, 0, [100]),
    ModRow("Dirty Deeds: 20 energy less Cheap Shot", [14082, 14083], 1833, SpellModOp.cost, 60, [50, 40]),
    ModRow("Dirty Deeds: 20 energy less Garrote", [14082, 14083], 11290, SpellModOp.cost, 50, [40, 30]),
    ModRow("Elusiveness: 1.5 min less Vanish cooldown", [13981, 14066], 1857, SpellModOp.cooldown, 300_000,
        [255_000, 210_000]),
    ModRow("Elusiveness: 1.5 min less Blind cooldown", [13981, 14066], 2094, SpellModOp.cooldown, 300_000,
        [255_000, 210_000]),
    ModRow("Endurance: 1.5 min less Sprint cooldown", [13742, 13872], 11305, SpellModOp.cooldown, 300_000,
        [255_000, 210_000]),
    ModRow("Endurance: 1.5 min less Evasion cooldown", [13742, 13872], 5277, SpellModOp.cooldown, 300_000,
        [255_000, 210_000]),
    ModRow("Improved Ambush: 45% more crit chance", [14079, 14080, 14081], 11269, SpellModOp.critChance, 0,
        [15, 30, 45]),
    ModRow("Improved Backstab: 30% more crit chance", [13733, 13865, 13866], 11281, SpellModOp.critChance, 0,
        [10, 20, 30]),
    ModRow("Improved Eviscerate: 15% more damage", [14162, 14163, 14164], 11300, SpellModOp.damage, 1000,
        [1050, 1100, 1150]),
    ModRow("Improved Expose Armor: 50% more armor reduced", [14168, 14169], 11198, SpellModOp.allEffects, 1000,
        [1250, 1500]),
    ModRow("Improved Gouge: 1.5 sec longer", [13741, 13793, 13792], 11286, SpellModOp.duration, 4000,
        [4500, 5000, 5500]),
    ModRow("Improved Kidney Shot: 9% more damage taken", [14174, 14175, 14176], 8643, SpellModOp.allEffects, 0,
        [3, 6, 9]),
    ModRow("Improved Poisons: 10% more chance (Instant Poison VI)", [14113, 14114, 14115, 14116, 14117], 11337,
        SpellModOp.chanceOfSuccess, 20, [22, 24, 26, 28, 30]),
    ModRow("Improved Sinister Strike: 5 energy less", [13732, 13863], 11294, SpellModOp.cost, 45, [42, 40]),
    ModRow("Improved Slice and Dice: 45% longer", [14165, 14166, 14167], 6774, SpellModOp.duration, 9000,
        [10_350, 11_700, 13_050]),
    ModRow("Lethality: 30% more crit damage bonus (Sinister Strike)", [14128, 14132, 14135, 14136, 14137], 11294,
        SpellModOp.critDamageBonus, 100, [106, 112, 118, 124, 130]),
    ModRow("Lethality: (Hemorrhage)", [14128, 14132, 14135, 14136, 14137], 17348, SpellModOp.critDamageBonus, 100,
        [106, 112, 118, 124, 130]),
    ModRow("Lethality: (Ghostly Strike)", [14128, 14132, 14135, 14136, 14137], 14278, SpellModOp.critDamageBonus, 100,
        [106, 112, 118, 124, 130]),
    ModRow("Lethality: (Gouge)", [14128, 14132, 14135, 14136, 14137], 11286, SpellModOp.critDamageBonus, 100,
        [106, 112, 118, 124, 130]),
    ModRow("Opportunity: 20% more Backstab damage", [14057, 14072, 14073, 14074, 14075], 11281, SpellModOp.damage,
        1000, [1040, 1080, 1120, 1160, 1200]),
    ModRow("Opportunity: 20% more Ambush damage", [14057, 14072, 14073, 14074, 14075], 11269, SpellModOp.damage,
        1000, [1040, 1080, 1120, 1160, 1200]),
    ModRow("Opportunity: 20% more Garrote damage", [14057, 14072, 14073, 14074, 14075], 11290, SpellModOp.dot,
        100, [104, 108, 112, 116, 120]),
    ModRow("Remorseless: 20% and 40% more crit chance", [14143, 14149], 11294, SpellModOp.critChance, 0, [20, 40]),
    ModRow("Remorseless: (Ghostly Strike)", [14143, 14149], 14278, SpellModOp.critChance, 0, [20, 40]),
    ModRow("Serrated Blades: 30% more Rupture damage", [14171, 14172, 14173], 11275, SpellModOp.dot, 100,
        [110, 120, 130]),
    ModRow("Sleight of Hand: 20% more Feint threat reduction", [30892, 30893], 11303, SpellModOp.allEffects, 100,
        [110, 120]),
    ModRow("Vile Poisons: 20% more poison damage", [16513, 16514, 16515, 16719, 16720], 11337, SpellModOp.damage,
        100, [104, 108, 112, 116, 120]),
    ModRow("Vile Poisons: 20% more Deadly Poison damage", [16513, 16514, 16515, 16719, 16720], 25349,
        SpellModOp.dot, 100, [104, 108, 112, 116, 120]),
    ModRow("Vile Poisons: 40% more chance to resist dispel", [16513, 16514, 16515, 16719, 16720], 25349,
        SpellModOp.resistDispelChance, 0, [8, 16, 24, 32, 40]),
    // Hunter
    ModRow("Barrage: 15% more Multi-Shot damage", [19461, 19462, 24691], 14290, SpellModOp.damage, 1000,
        [1050, 1100, 1150]),
    ModRow("Barrage: 15% more Volley damage", [19461, 19462, 24691], 14295, SpellModOp.dot, 1000, [1050, 1100, 1150]),
    ModRow("Clever Traps: 30% longer Freezing Trap", [19239, 19245], 14309, SpellModOp.duration, 20_000,
        [23_000, 26_000]),
    ModRow("Clever Traps: 30% longer Frost Trap", [19239, 19245], 13810, SpellModOp.duration, 30_000,
        [34_500, 39_000]),
    ModRow("Clever Traps: 30% more Immolation Trap damage", [19239, 19245], 14301, SpellModOp.allEffects, 1000,
        [1150, 1300]),
    ModRow("Clever Traps: 30% more Explosive Trap damage", [19239, 19245], 14315, SpellModOp.allEffects, 1000,
        [1150, 1300]),
    ModRow("Efficiency: 10% less mana for Arcane Shot", [19416, 19417, 19418, 19419, 19420], 14287, SpellModOp.cost,
        190, [186, 182, 178, 174, 171]),
    ModRow("Efficiency: (Serpent Sting)", [19416, 19417, 19418, 19419, 19420], 25295, SpellModOp.cost, 250,
        [245, 240, 235, 230, 225]),
    ModRow("Hawk Eye: 6 yards more range (Auto Shot)", [19498, 19499, 19500], 75, SpellModOp.range, 35, [37, 39, 41]),
    ModRow("Hawk Eye: (Aimed Shot)", [19498, 19499, 19500], 20904, SpellModOp.range, 35, [37, 39, 41]),
    ModRow("Improved Arcane Shot: 1 sec less cooldown", [19454, 19455, 19456, 19457, 19458], 14287,
        SpellModOp.cooldown, 6000, [5800, 5600, 5400, 5200, 5000]),
    ModRow("Improved Hunter's Mark: 15% more attack power", [19421, 19422, 19423, 19424, 19425], 14325,
        SpellModOp.allEffects, 100, [103, 106, 109, 112, 115]),
    ModRow("Improved Serpent Sting: 10% more damage", [19464, 19465, 19466, 19467, 19468], 25295, SpellModOp.dot,
        100, [102, 104, 106, 108, 110]),
    ModRow("Improved Revive Pet: 6 sec less casting time", [24443, 19575], 982, SpellModOp.castingTime, 10_000,
        [7000, 4000]),
    ModRow("Improved Revive Pet: 40% less mana", [24443, 19575], 982, SpellModOp.cost, 1000, [800, 600]),
    ModRow("Improved Revive Pet: 30% more health", [24443, 19575], 982, SpellModOp.allEffects, 15, [30, 45]),
    ModRow("Improved Eyes of the Beast: 60 sec longer", [19557, 19558], 1002, SpellModOp.duration, 60_000,
        [90_000, 120_000]),
    ModRow("Improved Feign Death: 4% less resisted", [19286, 19287], 5384, SpellModOp.resistMissChance, 0, [2, 4]),
    ModRow("Mortal Shots: 30% more crit damage bonus (Aimed Shot)", [19485, 19487, 19488, 19489, 19490], 20904,
        SpellModOp.critDamageBonus, 100, [106, 112, 118, 124, 130]),
    ModRow("Mortal Shots: (Auto Shot)", [19485, 19487, 19488, 19489, 19490], 75, SpellModOp.critDamageBonus, 100,
        [106, 112, 118, 124, 130]),
    ModRow("Pathfinding: 6% more Aspect of the Cheetah speed (its data's: the second effect's)", [19559, 19560],
        5118, SpellModOp.effect2, 0, [3, 6]),
    ModRow("Savage Strikes: 20% more Raptor Strike crit chance", [19159, 19160], 14266, SpellModOp.critChance, 0,
        [10, 20]),
    ModRow("Savage Strikes: (Mongoose Bite)", [19159, 19160], 14271, SpellModOp.critChance, 0, [10, 20]),
    ModRow("Trap Mastery: 10% less resisted (Freezing Trap)", [19376, 19377], 14309, SpellModOp.resistMissChance, 0,
        [5, 10]),
    ModRow("Improved Aspect of the Monkey: 5% more dodge", [19549, 19550, 19551, 24386, 24387], 13163,
        SpellModOp.allEffects, 8, [9, 10, 11, 12, 13]),
    ModRow("Improved Aspect of the Hawk: 5% for Quick Shots", [19552, 19553, 19554, 19555, 19556], 14322,
        SpellModOp.chanceOfSuccess, 0, [1, 2, 3, 4, 5]),
];

/// Each modifier talent's ranks change their spell as the tooltip says (by the modifiers the cast pipeline reads).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    uint guid = 100;
    foreach (ref row; modTable)
    {
        auto who = w.character(guid, format!"Mod%s"(guid), PlayerClass.warrior, 60, []);
        ++guid;
        auto me = who.session.inWorld;
        const spell = spellOf(w, row.spell);
        assert(applySpellMod(me.player.auras.list, row.op, *spell, row.base) == row.base, row.name ~ ": nothing without the talent");
        foreach (r, rank; row.ranks)
        {
            talent(w, who, rank);
            const got = applySpellMod(me.player.auras.list, row.op, *spell, row.base);
            assert(got == row.expected[r], format!"%s, rank %s (%s): %s, not %s"(row.name, r + 1, rank, got,
                row.expected[r]));
            drop(who, rank);
        }
    }
}

/// A spell's strike as its log tells it, including damage absorbed by a shield.
private struct Strike
{
    uint spell;
    ulong target;
    uint damage;
    bool crit;
    uint absorbed;
}

/// The energize logs (spell, amount) the last `strikes` read.
private uint[2][] energized;

/// The strikes (`SMSG_SPELLNONMELEEDAMAGELOG`) since the last read.
private Strike[] strikes(ref TestClient who)
{
    Strike[] all;
    energized = null;
    foreach (p; who.read())
        if (p.opcode == Opcode.SMSG_SPELLENERGIZELOG)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            const spell = r.read!uint;
            r.read!uint; // the power
            energized ~= [spell, r.read!uint];
        }
        else if (p.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
        {
            auto r = ByteReader(p.body_);
            Strike s;
            s.target = r.readPackedGuid();
            r.readPackedGuid();
            s.spell = r.read!uint;
            s.damage = r.read!uint;
            r.read!ubyte; // school
            s.absorbed = r.read!uint;
            r.read!int;   // resisted
            r.read!ubyte; // periodic
            r.read!ubyte;
            r.read!uint;  // blocked
            s.crit = (r.read!uint & 0x2) != 0;
            all ~= s;
        }
    return all;
}

/// The cast time `SMSG_SPELL_START` gave `spell` since the last read (uint.max: none).
private uint castTimeOf(ref TestClient who, uint spell)
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
            return r.read!uint;
        }
    return uint.max;
}

/// The periodic aura logs (`SMSG_PERIODICAURALOG`) since the last read: spell, aura type, amount (a heal's, a
/// damage's).
private uint[3][] periodicLogs(ref TestClient who)
{
    uint[3][] logs;
    foreach (p; who.read())
        if (p.opcode == Opcode.SMSG_PERIODICAURALOG)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            const spell = r.read!uint;
            r.read!uint;
            const type = r.read!uint;
            logs ~= [spell, type, r.read!uint];
        }
    return logs;
}

/// The creature of `guid` at full health again.
private void healFull(ref RealWorld w, ulong guid)
{
    auto c = creatureOf(w, guid);
    c.values.set!UNIT_FIELD_HEALTH(c.values.get!UNIT_FIELD_MAXHEALTH);
}

/// The character's weapon deals exactly `amount` (no roll): for damage tests.
private void fixedWeapon(ref TestClient who, uint amount, AttackType hand = AttackType.mainHand)
{
    auto me = who.session.inWorld;
    me.player.stats.damage[hand].min = amount;
    me.player.stats.damage[hand].max = amount;
}

enum uint battleStance = 2457, defensiveStance = 71, berserkerStance = 2458;
enum uint wornShortsword = 25, wornMace = 36, largeRoundShield = 2129, wornBattleaxe = 12282;

/// Takes a stance (its own cooldown past).
private void stance(ref RealWorld w, ref TestClient who, uint which)
{
    w.now += 2.seconds;
    const r = w.cast_(who, which);
    assert(r == SpellCastResult.ok, format!"stance %s: %s"(which, r));
    w.now += 2.seconds;
}

// ---------------------------------------------------------------------------
// Warrior
// ---------------------------------------------------------------------------

/**
 * The modifiers as the casts use them: Improved Sunder Armor's rage (12 of 15 spent), Improved Taunt's cooldown (8
 * sec), Improved Shield Wall's and Improved Shield Block's duration (15 and 7 sec) and Shield Block's extra charge,
 * Improved Battle Shout's attack power (a quarter more), Improved Bloodrage's rage (15 at once), Improved Slam's
 * cast time (1 sec).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(200, "Saurfang", PlayerClass.warrior, 60,
        [battleStance, defensiveStance, 11597, 355, 871, 2565, 11551, 2687, 11605], );
    auto me = who.session.inWorld;
    equip(who, wornShortsword);
    foreach (t; [12811u, 12765, 12803, 12944, 12861, 12818, 20499])
        talent(w, who, t);
    const kobold = foe(w, who, 448);
    auto target = creatureOf(w, kobold);
    // Sunder Armor, until one lands.
    bool sundered;
    foreach (_; 0 .. 20)
    {
        setPower(who, Power.rage, 500);
        w.now += 2.seconds;
        w.castAt(who, 11597, kobold);
        if (target.auras.find(11597) !is null)
        {
            assert(power(who, Power.rage) == 500 - 120, format!"Sunder Armor costs 12 rage: %s left"(power(who, Power.rage)));
            sundered = true;
            break;
        }
    }
    assert(sundered);
    // Bloodrage: 10 rage and 5 more at once.
    setPower(who, Power.rage, 0);
    assert(w.cast_(who, 2687) == SpellCastResult.ok);
    assert(power(who, Power.rage) == 150, format!"Bloodrage's 15 rage: %s"(power(who, Power.rage)));
    // Battle Shout: 185 (and a point a level past 52: 193 at 60) and 25%.
    w.now += 2.seconds;
    assert(w.cast_(who, 11551) == SpellCastResult.ok);
    assert(me.player.auras.find(11551).amount[0] == 193 * 125 / 100, format!"%s"(me.player.auras.find(11551).amount[0]));
    // Slam: a second's cast.
    w.now += 2.seconds;
    setPower(who, Power.rage, 1000);
    who.read();
    assert(w.castAt(who, 11605, kobold) == SpellCastResult.ok);
    const slam = castTimeOf(who, 11605);
    assert(slam == 1000, format!"Slam's cast: %s"(slam));
    pass(w, who, 1100.msecs);
    // Defensive Stance with a shield: Taunt, Shield Wall, Shield Block.
    equip(who, largeRoundShield);
    stance(w, who, defensiveStance);
    setPower(who, Power.rage, 1000);
    healFull(w, kobold);
    {
        const r = w.castAt(who, 355, kobold);
        assert(r == SpellCastResult.ok, format!"Taunt: %s"(r));
    }
    w.now += 7900.msecs;
    assert(!me.spellIsReady(355), "Taunt not ready before 8 sec");
    w.now += 200.msecs;
    assert(me.spellIsReady(355), "Taunt ready at 8 sec, not 10");
    assert(w.cast_(who, 871) == SpellCastResult.ok);
    assert(me.player.auras.find(871).maxDuration == 15_000, "Shield Wall: 15 sec");
    w.now += 2.seconds;
    assert(w.cast_(who, 2565) == SpellCastResult.ok);
    auto block = me.player.auras.find(2565);
    assert(block.maxDuration == 7000, format!"Shield Block: 7 sec, %s"(block.maxDuration));
    assert(block.charges == 2, format!"Shield Block: two attacks, %s"(block.charges));
}

/**
 * Impale (16494: crits of the warrior's abilities deal 20% more crit bonus: 2.2 times, not 2) on Mortal Strike
 * (21553), and Improved Overpower (12963: 50% more crit chance) on Overpower (11585).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(201, "Grommash", PlayerClass.warrior, 60, [battleStance, 21553, 11585]);
    auto me = who.session.inWorld;
    equip(who, wornShortsword);
    stance(w, who, battleStance);
    giveAura(w, who, 1719); // Recklessness: every strike a crit
    const hogger = foe(w, who, 448);
    // The damage of a crit of Mortal Strike.
    uint critOf()
    {
        foreach (_; 0 .. 30)
        {
            healFull(w, hogger);
            setPower(who, Power.rage, 1000);
            fixedWeapon(who, 100);
            who.read();
            w.now += 7.seconds;
            w.castAt(who, 21553, hogger);
            foreach (s; strikes(who))
                if (s.spell == 21553 && s.crit && s.damage)
                    return s.damage;
        }
        assert(false, "no crit");
    }
    const plainCrit = critOf();
    talent(w, who, 16494);
    const impaled = critOf();
    assert(impaled * 10 >= plainCrit * 11 - 10 && impaled * 10 <= plainCrit * 11 + 10,
        format!"Impale: 2.2 times not 2: %s against %s"(impaled, plainCrit));

    // Improved Overpower: half again of them crit (the share of crits, out of 300 that land, with and without it).
    drop(who, 1719);
    uint[2] overpowers()
    {
        uint crits, landed;
        while (landed < 300)
        {
            healFull(w, hogger);
            setPower(who, Power.rage, 1000);
            me.swingDodgedBy(hogger, MeleeHitOutcome.dodge); // the dodge Overpower needs
            who.read();
            w.now += 6.seconds;
            w.castAt(who, 11585, hogger);
            foreach (s; strikes(who))
                if (s.spell == 11585 && s.damage)
                {
                    ++landed;
                    crits += s.crit;
                }
        }
        return [crits, landed];
    }
    const plain = overpowers();
    talent(w, who, 12963);
    const improved = overpowers();
    assert(improved[0] >= plain[0] + 100, format!"Improved Overpower: %s crits against %s of 300"(improved[0], plain[0]));
}

/**
 * Blood Craze (16487, 16489, 16492: 1%, 2%, 3% of the health over 6 sec) and Enrage (12317...13048: 5% to 25% more
 * melee damage, 12 swings, 12 sec) after a critical strike taken; not after a plain hit.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    static immutable uint[2][] bloodCraze = [[16487, 16488], [16489, 16490], [16492, 16491]];
    static immutable uint[3][] enrage = [[12317, 12880, 5], [13045, 14201, 10], [13046, 14202, 15],
        [13047, 14203, 20], [13048, 14204, 25]];
    uint guid = 210;
    foreach (r, rank; bloodCraze)
    {
        auto who = w.character(guid++, format!"Craze%s"(r), PlayerClass.warrior, 60, []);
        auto me = who.session.inWorld;
        talent(w, who, rank[0]);
        const kobold = foe(w, who);
        struck(w, who, kobold, MeleeHitOutcome.normal);
        assert(me.player.auras.find(rank[1]) is null, "not after a plain hit");
        struck(w, who, kobold, MeleeHitOutcome.crit);
        assert(me.player.auras.find(rank[1]) !is null, "after a crit");
        const max = me.player.values.get!UNIT_FIELD_MAXHEALTH;
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
        who.read();
        uint healed;
        foreach (_; 0 .. 7)
        {
            pass(w, who, 1000.msecs);
            foreach (l; periodicLogs(who))
                if (l[0] == rank[1])
                    healed += l[2];
        }
        assert(healed >= max * (r + 1) / 100 - 2 && healed <= max * (r + 1) / 100 + 2,
            format!"Blood Craze rank %s: %s of %s"(r + 1, healed, max));
    }
    foreach (r, rank; enrage)
    {
        auto who = w.character(guid++, format!"Enrage%s"(r), PlayerClass.warrior, 60, []);
        auto me = who.session.inWorld;
        talent(w, who, rank[0]);
        const kobold = foe(w, who, 448);
        struck(w, who, kobold, MeleeHitOutcome.normal);
        assert(me.player.auras.find(rank[1]) is null, "not after a plain hit");
        struck(w, who, kobold, MeleeHitOutcome.crit);
        auto aura = me.player.auras.find(rank[1]);
        assert(aura !is null, "after a crit");
        assert(aura.amount[0] == rank[2] && aura.charges == 12 && aura.maxDuration == 12_000,
            format!"Enrage rank %s: %s%%, %s swings, %s ms"(r + 1, aura.amount[0], aura.charges, aura.maxDuration));
        // Each swing that lands takes one of the twelve.
        auto target = creatureOf(w, kobold);
        uint swings;
        while (me.player.auras.find(rank[1]) !is null && swings < 200)
        {
            target.values.set!UNIT_FIELD_HEALTH(target.values.get!UNIT_FIELD_MAXHEALTH);
            me.swing(target, AttackType.mainHand);
            ++swings;
        }
        assert(swings >= 12 && swings < 200, format!"Enrage gone after 12 swings that land: %s"(swings));
    }
}

/// Flurry (12319, 12971...12974: 10% to 30% attack speed for the next 3 swings) after the warrior's critical strike.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    static immutable uint[3][] flurry = [[12319, 12966, 10], [12971, 12967, 15], [12972, 12968, 20],
        [12973, 12969, 25], [12974, 12970, 30]];
    foreach (r, rank; flurry)
    {
        auto who = w.character(220 + cast(uint) r, format!"Flurry%s"(r), PlayerClass.warrior, 60, []);
        auto me = who.session.inWorld;
        talent(w, who, rank[0]);
        equip(who, wornShortsword); // (Recklessness's crits are a weapon's)
        const kobold = foe(w, who, 448);
        auto target = creatureOf(w, kobold);
        auto reckless = giveAura(w, who, 1719); // crits
        foreach (_; 0 .. 20)
        {
            me.swing(target, AttackType.mainHand);
            if (me.player.auras.find(rank[1]) !is null)
                break;
        }
        auto aura = me.player.auras.find(rank[1]);
        assert(aura !is null, "Flurry after a crit");
        assert(aura.amount[0] == rank[2] && aura.charges == 3, format!"rank %s: %s%% %s swings"(r + 1,
            aura.amount[0], aura.charges));
        me.removeAura(reckless);
        // Three swings (no crit among them to renew it; a miss counts as well) and it is gone.
        uint swings;
        while (me.player.auras.find(rank[1]) !is null && swings < 50)
        {
            healFull(w, kobold);
            me.swing(target, AttackType.mainHand);
            ++swings;
        }
        assert(swings < 50, "Flurry spent");
    }
}

/**
 * Improved Berserker Rage (20500, 20501: 5 and 10 rage) as Berserker Rage (18499) is used; Berserker Rage's
 * immunity to fear.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (r, rank; [20500u, 20501])
    {
        auto who = w.character(230 + cast(uint) r, format!"Berserk%s"(r), PlayerClass.warrior, 60,
            [berserkerStance, 18499]);
        talent(w, who, rank);
        stance(w, who, berserkerStance);
        setPower(who, Power.rage, 0);
        assert(w.cast_(who, 18499) == SpellCastResult.ok);
        assert(power(who, Power.rage) == (r + 1) * 50, format!"rank %s: %s rage"(r + 1, power(who, Power.rage)));
        assert(who.session.inWorld.player.fighter.immune.toMechanic(5), "immune to fear");
    }
}

/**
 * Shield Specialization (12298, 12724...12727: 1% to 5% block, 20% to 100% for a rage point at a block) and Shield Block (2565: 75%
 * block, gone after one block).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (r, rank; [12298u, 12724, 12725, 12726, 12727])
    {
        auto who = w.character(240 + cast(uint) r, format!"Shield%s"(r), PlayerClass.warrior, 60,
            [defensiveStance, 2565]);
        auto me = who.session.inWorld;
        equip(who, largeRoundShield);
        const before = me.player.fighter.block;
        talent(w, who, rank);
        me.player.refreshEquipmentStats(w.context.data);
        assert(me.player.fighter.block - before > r + 0.9f && me.player.fighter.block - before < r + 1.1f,
            format!"rank %s: %s%% more block"(r + 1, me.player.fighter.block - before));
        const kobold = foe(w, who);
        // A rage point at 20% to 100% of the blocks (a blow of no damage: no rage of its own).
        setPower(who, Power.rage, 0);
        enum blocks = 90; // (fewer than the 100 rage at most)
        foreach (_; 0 .. blocks)
            struck(w, who, kobold, MeleeHitOutcome.block, 0);
        const points = power(who, Power.rage) / 10, chance = 20 * (r + 1);
        assert(power(who, Power.rage) % 10 == 0 && points * 100 >= blocks * (chance - 15)
            && points * 100 <= blocks * (chance + 15), format!"rank %s: %s rage points of %s blocks"(r + 1, points,
            blocks));
        if (r == 0)
        {
            stance(w, who, defensiveStance);
            setPower(who, Power.rage, 1000);
            assert(w.cast_(who, 2565) == SpellCastResult.ok);
            assert(me.player.auras.find(2565) !is null);
            struck(w, who, kobold, MeleeHitOutcome.normal);
            assert(me.player.auras.find(2565) !is null, "kept through a hit");
            struck(w, who, kobold, MeleeHitOutcome.block);
            assert(me.player.auras.find(2565) is null, "Shield Block blocks one attack");
        }
    }
}

/// Revenge (11601): only after a block, a dodge or a parry, for a while.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(250, "Revenger", PlayerClass.warrior, 60, [defensiveStance, 11601]);
    auto me = who.session.inWorld;
    equip(who, wornShortsword);
    stance(w, who, defensiveStance);
    const kobold = foe(w, who, 448);
    setPower(who, Power.rage, 1000);
    {
        const r = w.castAt(who, 11601, kobold);
        assert(r == SpellCastResult.casterAuraState, format!"not before: %s"(r));
    }
    foreach (outcome; [MeleeHitOutcome.block, MeleeHitOutcome.dodge, MeleeHitOutcome.parry])
    {
        struck(w, who, kobold, outcome);
        w.now += 6.seconds; // its cooldown
        const r = w.castAt(who, 11601, kobold);
        assert(r == SpellCastResult.ok, format!"after a %s: %s"(outcome, r));
    }
    me.updateReactives(4000); // four seconds on (no map update: Hogger would swing again)
    w.now += 6.seconds;
    assert(w.castAt(who, 11601, kobold) == SpellCastResult.casterAuraState, "the state lasts a while only");
}

/**
 * Improved Hamstring (12289, 12668, 23695: 5%, 10%, 15% to root the target 5 sec, 23694), Improved Revenge (12797,
 * 12799, 12800: 15%, 30%, 45% to stun 3 sec, 12798) and Improved Shield Bash (12311, 12958: 50%, 100% to silence 3
 * sec, 18498): of their own ability only.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    struct Row
    {
        uint[] ranks;
        uint[] percent;
        uint ability, effect, duration, stanceId;
    }
    const rows = [Row([12289, 12668, 23695], [5, 10, 15], 7373, 23694, 5000, battleStance),
        Row([12797, 12799, 12800], [15, 30, 45], 11601, 12798, 3000, defensiveStance),
        Row([12311, 12958], [50, 100], 1672, 18498, 3000, defensiveStance)];
    uint guid = 260;
    foreach (row; rows)
        foreach (r, rank; row.ranks)
        {
            auto who = w.character(guid, format!"Imp%s"(guid), PlayerClass.warrior, 60,
                [battleStance, defensiveStance, row.ability, 11597]);
            ++guid;
            auto me = who.session.inWorld;
            equip(who, wornShortsword);
            equip(who, largeRoundShield);
            talent(w, who, rank);
            stance(w, who, row.stanceId);
            const hogger = foe(w, who, 448);
            auto target = creatureOf(w, hogger);
            uint landed, procced;
            foreach (_; 0 .. 400)
            {
                if (auto a = target.auras.find(row.effect))
                {
                    assert(a.maxDuration == row.duration, format!"%s lasts %s"(row.effect, a.maxDuration));
                    target.auras.remove(a, target.values);
                }
                healFull(w, hogger);
                setPower(who, Power.rage, 1000);
                if (row.ability == 11601)
                    struck(w, who, hogger, MeleeHitOutcome.dodge);
                who.read();
                w.now += 13.seconds;
                w.castAt(who, row.ability, hogger);
                if (strikes(who).canFind!(s => s.spell == row.ability && s.damage))
                {
                    ++landed;
                    procced += target.auras.find(row.effect) !is null;
                }
            }
            const expected = landed * row.percent[r] / 100.0;
            import std.math : abs, sqrt;
            assert(abs(procced - expected) <= 4 * sqrt(expected * (1 - row.percent[r] / 100.0)) + 1,
                format!"%s rank %s: %s of %s, %s%%"(row.effect, r + 1, procced, landed, row.percent[r]));
            // Not of another ability.
            foreach (a; target.auras.list.dup)
                if (a.spell.id == row.effect)
                    target.auras.remove(a, target.values);
            foreach (_; 0 .. 10)
            {
                setPower(who, Power.rage, 1000);
                w.now += 2.seconds;
                w.castAt(who, 11597, hogger);
            }
            assert(target.auras.find(row.effect) is null, "Sunder Armor sets it off");
        }
}

/// Swings of `who` at `target` (kept alive) until `count` of them dealt damage: what `each` makes of each.
private void landSwings(ref RealWorld w, ref TestClient who, ulong target, uint count, void delegate() each,
    AttackType hand = AttackType.mainHand)
{
    auto me = who.session.inWorld;
    auto victim = creatureOf(w, target);
    uint landed;
    foreach (_; 0 .. count * 4)
    {
        healFull(w, target);
        who.read();
        w.now += 3100.msecs; // past a proc's cooldown (Unbridled Wrath's 3 sec, spell_proc_event's)
        const before = victim.values.get!UNIT_FIELD_HEALTH;
        me.swing(victim, hand);
        if (victim.values.get!UNIT_FIELD_HEALTH < before)
        {
            each();
            if (++landed == count)
                return;
        }
        else
            who.read();
    }
    assert(false, "the swings did not land");
}

/**
 * Unbridled Wrath (12322, 12999...13002: 8% to 40% for a rage point on a weapon's damage: the tooltip's flat
 * chance, not a rate a minute) and the weapon specializations: Sword Specialization (12281, 12812...12815: 1% to 5%
 * for an extra attack, with a sword only) and Mace Specialization (12284, 12701...12704: 1% to 6% to stun 3 sec, 5530,
 * with a mace only).
 */
unittest
{
    if (!haveRealData())
        return;
    import std.math : abs, sqrt;

    auto w = RealWorld.make();
    // The chance seen of `n` tries is `percent`'s.
    void near(uint seen, uint n, double percent, string what)
    {
        const expected = n * percent / 100;
        assert(abs(seen - expected) <= 4 * sqrt(expected * (1 - percent / 100)) + 1,
            format!"%s: %s of %s, not %s%%"(what, seen, n, percent));
    }
    uint guid = 300;
    foreach (r, rank; [12322u, 12999, 13000, 13001, 13002])
    {
        if (r != 0 && r != 4)
            continue; // the first and the last
        auto who = w.character(guid++, format!"Wrath%s"(r), PlayerClass.warrior, 60, []);
        equip(who, wornShortsword);
        talent(w, who, rank);
        const hogger = foe(w, who, 448);
        uint points;
        enum n = 600;
        landSwings(w, who, hogger, n, () {
            foreach (l; spellLogs(who, Opcode.SMSG_SPELLENERGIZELOG))
                points += l[0] == 12964;
        });
        near(points, n, 8.0 * (r + 1), format!"Unbridled Wrath rank %s"(r + 1));
    }
    // Sword Specialization: the extra swing owed.
    {
        auto who = w.character(guid++, "Swordsman", PlayerClass.warrior, 60, []);
        auto me = who.session.inWorld;
        equip(who, wornShortsword);
        giveAura(w, who, 12815);
        const hogger = foe(w, who, 448);
        uint extra;
        enum n = 1000;
        landSwings(w, who, hogger, n, () {
            extra += me.extraAttacks != 0;
            me.extraAttacks = 0;
        });
        near(extra, n, 5, "Sword Specialization");
        auto mace = w.character(guid++, "NoSword", PlayerClass.warrior, 60, []);
        equip(mace, wornMace);
        giveAura(w, mace, 12815);
        const kobold = foe(w, mace, 448);
        extra = 0;
        landSwings(w, mace, kobold, 200, () {
            extra += mace.session.inWorld.extraAttacks != 0;
        });
        assert(extra == 0, "not with a mace");
    }
    // Mace Specialization: the stun.
    {
        auto who = w.character(guid++, "Maceman", PlayerClass.warrior, 60, []);
        equip(who, wornMace);
        giveAura(w, who, 12704);
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        uint stuns;
        enum n = 1000;
        landSwings(w, who, hogger, n, () {
            if (auto stun = target.auras.find(5530))
            {
                ++stuns;
                assert(stun.maxDuration == 3000);
                target.auras.remove(stun, target.values);
            }
        });
        near(stuns, n, 6, "Mace Specialization");
        auto sword = w.character(guid++, "NoMace", PlayerClass.warrior, 60, []);
        equip(sword, wornShortsword);
        giveAura(w, sword, 12704);
        const kobold = foe(w, sword, 448);
        landSwings(w, sword, kobold, 200, () {});
        assert(creatureOf(w, kobold).auras.find(5530) is null, "not with a sword");
    }
}

/**
 * Deep Wounds (12834, 12849, 12867: 20%, 40%, 60% of the weapon's average damage over 12 sec, 12721) at the
 * warrior's crit.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (r, rank; [12834u, 12849, 12867])
    {
        auto who = w.character(310 + cast(uint) r, format!"Wounds%s"(r), PlayerClass.warrior, 60, []);
        auto me = who.session.inWorld;
        equip(who, wornShortsword);
        giveAura(w, who, rank);
        giveAura(w, who, 1719); // crits
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        foreach (_; 0 .. 20)
        {
            healFull(w, hogger);
            me.player.values.set!UNIT_FIELD_MINDAMAGE(100.0f); // its average: 100
            me.player.values.set!UNIT_FIELD_MAXDAMAGE(100.0f);
            me.swing(target, AttackType.mainHand);
            if (target.auras.find(12721) !is null)
                break;
        }
        auto bleed = target.auras.find(12721);
        assert(bleed !is null, "a crit's bleed");
        const share = 20 * (r + 1);
        assert(bleed.maxDuration == 12_000 && bleed.amount[0] * 4 == share,
            format!"rank %s: %s a tick over %s ms, %s in all"(r + 1, bleed.amount[0], bleed.maxDuration, share));
    }
}

/// Last Stand (12975): 30% of the maximum health for 20 sec, lost after.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(320, "Stander", PlayerClass.warrior, 60, [12975]);
    auto me = who.session.inWorld;
    const max = me.player.values.get!UNIT_FIELD_MAXHEALTH;
    assert(w.cast_(who, 12975) == SpellCastResult.ok);
    auto aura = me.player.auras.find(12976);
    assert(aura !is null && aura.maxDuration == 20_000, "Last Stand's health for 20 sec");
    assert(me.player.values.get!UNIT_FIELD_MAXHEALTH == max + max * 30 / 100,
        format!"%s more of %s"(me.player.values.get!UNIT_FIELD_MAXHEALTH - max, max));
    assert(me.player.values.get!UNIT_FIELD_HEALTH == max + max * 30 / 100, "granted: the health too");
    me.removeAura(aura);
    assert(me.player.values.get!UNIT_FIELD_MAXHEALTH == max && me.player.values.get!UNIT_FIELD_HEALTH <= max, "lost");
}

/// Tactical Mastery (12295, 12676...12679: 5 to 25 rage kept at a stance change; none without it).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (r, rank; [0u, 12295, 12676, 12677, 12678, 12679])
    {
        auto who = w.character(330 + cast(uint) r, format!"Tactic%s"(r), PlayerClass.warrior, 60,
            [battleStance, defensiveStance]);
        if (rank)
            talent(w, who, rank);
        stance(w, who, battleStance);
        setPower(who, Power.rage, 600);
        stance(w, who, defensiveStance);
        assert(who.session.inWorld.player.auras.find(battleStance) is null, "out of Battle Stance");
        assert(power(who, Power.rage) == r * 50, format!"rank %s: %s rage kept"(r, power(who, Power.rage)));
        setPower(who, Power.rage, 20);
        stance(w, who, battleStance);
        assert(power(who, Power.rage) == (r ? 20 : 0), format!"what is under the most kept is kept: rank %s, %s"(r, power(who, Power.rage)));
    }
}

/// Execute (20662: 600, and 15 for each point of rage past its cost, all spent) at a target under a fifth of its
/// health only.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(340, "Executioner", PlayerClass.warrior, 60, [battleStance, 20662]);
    equip(who, wornShortsword);
    stance(w, who, battleStance);
    const hogger = foe(w, who, 448);
    auto target = creatureOf(w, hogger);
    setPower(who, Power.rage, 1000);
    assert(w.castAt(who, 20662, hogger) == SpellCastResult.targetAuraState, "not at full health");
    // The damage of an Execute with `rage` (a hit: the crits aside), and the rage left.
    uint[2] execute(uint rage)
    {
        foreach (_; 0 .. 40)
        {
            target.values.set!UNIT_FIELD_HEALTH(target.values.get!UNIT_FIELD_MAXHEALTH / 10);
            w.context.map(0).flushObjectChanges(target);
            setPower(who, Power.rage, rage);
            who.read();
            w.now += 2.seconds;
            const r = w.castAt(who, 20662, hogger);
            assert(r == SpellCastResult.ok, format!"Execute: %s"(r));
            foreach (s; strikes(who))
                if (s.spell == 20647 && s.damage && !s.crit)
                    return [s.damage, power(who, Power.rage)];
        }
        assert(false, "no Execute landed");
    }
    const plain = execute(150), more = execute(500);
    assert(plain[1] == 0 && more[1] == 0, "all the rage spent");
    // (armor takes the same share of both)
    const expected = plain[0] * (600.0 + 35 * 15) / 600;
    assert(more[0] >= expected - 2 && more[0] <= expected + 2, format!"35 rage more: %s, %s"(plain[0], more[0]));
}

/**
 * Sweeping Strikes (12292: the next 5 melee attacks strike another enemy near as well) and Retaliation (20230: not
 * at a swing from behind).
 */
unittest
{
    import dmangos.world.combat : MeleeDamage;
    import dmangos.world.unit : Blow, dealDamage;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(350, "Sweeper", PlayerClass.warrior, 60, [battleStance, 12292, 20230]);
    auto me = who.session.inWorld;
    equip(who, wornShortsword);
    stance(w, who, battleStance);
    const first = foe(w, who, 448), second = foe(w, who, 448);
    setPower(who, Power.rage, 1000);
    {
        const r = w.cast_(who, 12292);
        assert(r == SpellCastResult.ok, format!"Sweeping Strikes: %s"(r));
    }
    assert(me.player.auras.find(12292).charges == 5);
    uint seconds;
    landSwings(w, who, first, 5, () {
        healFull(w, second);
        foreach (s; strikes(who))
            seconds += s.target == second && s.spell == 12723;
    });
    assert(seconds == 5 && me.player.auras.find(12292) is null, format!"five strikes at the other: %s"(seconds));
    // Retaliation: a swing from behind (the warrior turned away) is not struck back.
    w.now += 2.seconds;
    assert(w.cast_(who, 20230) == SpellCastResult.ok);
    import std.math : PI;
    me.player.movement.position.orientation = PI; // facing west, Hogger to the east: behind
    who.read();
    MeleeDamage d;
    d.attacker = first;
    d.target = me.player.guid;
    d.outcome = MeleeHitOutcome.normal;
    d.damage = 5;
    dealDamage(w.context.map(0).unit(first), me.unit, 5, Blow.swing(d));
    assert(!strikes(who).canFind!(s => s.spell == 20240), "not from behind");
    assert(me.player.auras.find(20230).charges == 30, "no charge spent");
}

/// Power Word: Shield on the first creature prevents Sweeping Strikes while it absorbs all the damage.
unittest
{
    if (!haveRealData())
        return;
    enum uint sweepingStrikes = 12292, sweepingHit = 12723, heroicStrike = 11567, shield = 10901;
    auto w = RealWorld.make();
    auto who = w.character(351, "Shieldsweeper", PlayerClass.warrior, 60, [battleStance, sweepingStrikes, heroicStrike]);
    auto me = who.session.inWorld;
    equip(who, wornShortsword);
    stance(w, who, battleStance);
    auto first = creatureOf(w, foe(w, who, 448));
    auto second = creatureOf(w, foe(w, who, 448));
    auto map = w.context.map(0);
    first.values.set!UNIT_FIELD_RESISTANCES(0, 0);
    second.values.set!UNIT_FIELD_RESISTANCES(0, 0);
    setPower(who, Power.rage, 1000);
    assert(w.cast_(who, sweepingStrikes) == SpellCastResult.ok);
    auto sweep = me.player.auras.find(sweepingStrikes);

    void giveShield(int amount)
    {
        bool isNew;
        first.auras.apply(makeAura(spellOf(w, shield), first.guid, 60, 30_000, true, [amount, 0, 0]), first.values, isNew);
    }

    const originalHealth = first.values.get!UNIT_FIELD_HEALTH;
    const otherHealth = second.values.get!UNIT_FIELD_HEALTH;
    giveShield(1000);
    foreach (_; 0 .. 20)
    {
        if (first.auras.find(shield).amount[0] < 1000 || sweep.charges < 5)
            break;
        me.swing(first, AttackType.mainHand);
    }
    assert(first.auras.find(shield).amount[0] < 1000, "a white swing was absorbed");
    assert(first.values.get!UNIT_FIELD_HEALTH == originalHealth && second.values.get!UNIT_FIELD_HEALTH == otherHealth,
        "the shield absorbs a white swing completely and there is no second strike");
    assert(sweep.charges == 5, "a white swing absorbed in full leaves all Sweeping Strikes charges");

    Strike landedHeroicStrike()
    {
        foreach (_; 0 .. 20)
        {
            w.now += 2.seconds;
            setPower(who, Power.rage, 1000);
            who.read();
            assert(w.castAt(who, heroicStrike, first.guid) == SpellCastResult.ok);
            me.swing(first, AttackType.mainHand);
            const hits = strikes(who);
            foreach (hit; hits)
                if (hit.spell == heroicStrike && hit.target == first.guid)
                {
                    foreach (other; hits)
                        if (other.spell == sweepingHit && other.target == second.guid)
                            assert(other.damage == hit.damage, "Sweeping Strikes repeats the damage left after the absorb");
                    return hit;
                }
        }
        assert(false, "Heroic Strike never landed");
    }

    auto full = landedHeroicStrike();
    assert(full.damage == 0 && full.absorbed > 0 && sweep.charges == 5, "a fully absorbed Heroic Strike spends no charge");
    assert(first.values.get!UNIT_FIELD_HEALTH == originalHealth && second.values.get!UNIT_FIELD_HEALTH == otherHealth);

    first.loseAura(first.auras.find(shield), map);
    giveShield(10);
    auto partial = landedHeroicStrike();
    assert(partial.absorbed == 10 && partial.damage > 0 && sweep.charges == 4, "a partly absorbed strike spends one charge");
    assert(first.auras.find(shield) is null, "a depleted shield goes away");
    assert(first.values.get!UNIT_FIELD_HEALTH == originalHealth - partial.damage
        && second.values.get!UNIT_FIELD_HEALTH == otherHealth - partial.damage, "both creatures take the same unabsorbed damage");
}

/**
 * Intimidating Shout (5246): its target cowers (20511, 8 sec), up to 5 enemies near flee (5246's fear, 8 sec).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = w.character(360, "Shouter", PlayerClass.warrior, 60, [5246]);
    ulong[] foes;
    foreach (_; 0 .. 7)
        foes ~= foe(w, who, 448);
    setPower(who, Power.rage, 1000);
    const r = w.castAt(who, 5246, foes[0]);
    assert(r == SpellCastResult.ok, format!"%s"(r));
    auto target = creatureOf(w, foes[0]);
    assert(target.auras.find(20511) !is null && target.auras.find(20511).maxDuration == 8000, "the target cowers");
    uint fleeing;
    foreach (f; foes)
        fleeing += creatureOf(w, f).auras.find(5246) !is null;
    assert(fleeing >= 1 && fleeing <= 5, format!"up to 5 flee: %s"(fleeing));
}

// ---------------------------------------------------------------------------
// Rogue
// ---------------------------------------------------------------------------

enum uint sinisterStrike = 11294, backstab = 11281, ambush = 11269, garrote = 11290, cheapShot = 1833,
    eviscerate = 11300, sliceAndDice = 6774, exposeArmor = 11198, rupture = 11275, kidneyShot = 8643, kick = 1769,
    sap = 11297, stealth = 1787, sprint = 11305, wornDagger = 2092;

/// A rogue of `guid` with a dagger (in hand: its skills at their best), knowing `spells`, before a Hogger.
private TestClient rogue(ref RealWorld w, uint guid, const(uint)[] spells, uint weapon = wornDagger)
{
    auto who = w.character(guid, format!"Rogue%s"(guid), PlayerClass.rogue, 60, spells);
    equip(who, weapon);
    return who;
}

/// The rogue's `spell` at `target` with `points` combo points on it until one lands: the strike's log (none if none
/// dealt damage) and the cast's result.
private Strike finisher(ref RealWorld w, ref TestClient who, uint spell, ulong target, ubyte points)
{
    auto me = who.session.inWorld;
    foreach (_; 0 .. 30)
    {
        healFull(w, target);
        me.clearComboPoints();
        me.addComboPoints(target, points);
        setPower(who, Power.energy, 100);
        who.read();
        w.now += 2.seconds;
        const r = w.castAt(who, spell, target);
        assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
        if (me.comboPoints != points || me.comboTarget != target) // spent (Ruthlessness may give one back)
        {
            foreach (s; strikes(who))
                if (s.spell == spell)
                    return s;
            return Strike(spell, target, 0, false);
        }
    }
    assert(false, "never landed");
}

/**
 * Aggression (18429: 6% more Sinister Strike damage) on the whole strike; Cold Blood (14177: the next Sinister
 * Strike a crit, then gone).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 400, [sinisterStrike, 14177]);
    auto me = who.session.inWorld;
    const hogger = foe(w, who, 448);
    uint hitOf()
    {
        foreach (_; 0 .. 40)
        {
            healFull(w, hogger);
            setPower(who, Power.energy, 100);
            fixedWeapon(who, 100);
            who.read();
            w.now += 2.seconds;
            w.castAt(who, sinisterStrike, hogger);
            foreach (s; strikes(who))
                if (s.spell == sinisterStrike && s.damage && !s.crit)
                    return s.damage;
        }
        assert(false, "no hit");
    }
    const plain = hitOf();
    talent(w, who, 18429);
    const more = hitOf();
    assert(more * 100 >= plain * 106 - 100 && more * 100 <= plain * 106 + 100, format!"6%% more: %s, %s"(plain, more));

    foreach (_; 0 .. 3)
    {
        w.now += 200.seconds; // Cold Blood's cooldown
        assert(w.cast_(who, 14177) == SpellCastResult.ok);
        bool landed;
        foreach (attempt; 0 .. 20)
        {
            healFull(w, hogger);
            setPower(who, Power.energy, 100);
            who.read();
            w.now += 2.seconds;
            w.castAt(who, sinisterStrike, hogger);
            foreach (s; strikes(who))
                if (s.spell == sinisterStrike && s.damage)
                {
                    assert(s.crit, "Cold Blood's Sinister Strike crits");
                    landed = true;
                }
            if (landed)
                break;
        }
        assert(landed && me.player.auras.find(14177) is null, "Cold Blood spent");
    }
}

/// Eviscerate (11300): its damage by its combo points (5: 803 to 899) and 3% of the attack power for each.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 401, [eviscerate]);
    auto me = who.session.inWorld;
    const hogger = foe(w, who, 448);
    uint[] withoutPower, withPower;
    foreach (k; 0 .. 16)
    {
        const power = k % 2 ? 1000 : 0;
        me.player.stats.attackPower = power;
        const s = finisher(w, who, eviscerate, hogger, 5);
        if (s.damage && !s.crit)
            (power ? withPower : withoutPower) ~= s.damage;
    }
    import std.algorithm.searching : maxElement, minElement;
    assert(withPower.length && withoutPower.length);
    // 5 points: 803 to 899, and 150 (1000 attack power, 3% a point): never as little with the power as without.
    assert(withPower.minElement > withoutPower.maxElement, format!"%s against %s"(withPower, withoutPower));
    // Armor takes a share of both: 1049 at most with, 803 at least without.
    assert(withPower.maxElement * 803 <= withoutPower.minElement * 1049 + 1049, format!"at most 150 more: %s against %s"(withPower, withoutPower));
}

/**
 * The finishing moves' lengths and amounts by combo points: Slice and Dice (6774: 9 to 21 sec; Improved Slice and Dice
 * 14167: 45% longer), Kidney Shot (8643: 2 to 6 sec; Improved Kidney Shot 14176: 9% more damage taken), Expose Armor
 * (11198: 340 armor a point; Improved Expose Armor 14169: 50% more), Rupture (11275: 60 and 8 a point a tick, 8 to 16
 * sec, and 1% of the attack power a point a tick, of 3 points at most).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 402, [sliceAndDice, kidneyShot, exposeArmor, rupture]);
    auto me = who.session.inWorld;
    foreach (ubyte points; 1 .. 6)
    {
        const kobold = foe(w, who, 448);
        auto target = creatureOf(w, kobold);
        me.addComboPoints(kobold, points);
        setPower(who, Power.energy, 100);
        w.now += 2.seconds;
        {
            const r = w.castAt(who, sliceAndDice, kobold); // (the client names its target: the points are on it)
            assert(r == SpellCastResult.ok, format!"Slice and Dice: %s"(r));
        }
        const snd = me.player.auras.find(sliceAndDice);
        assert(snd.maxDuration == (6 + 3 * points) * 1000 && snd.amount[1] == 30,
            format!"Slice and Dice, %s points: %s ms"(points, snd.maxDuration));
        me.removeAura(me.player.auras.find(sliceAndDice));
        finisher(w, who, kidneyShot, kobold, points);
        if (auto stun = target.auras.find(kidneyShot))
            assert(stun.maxDuration == (1 + points) * 1000, format!"Kidney Shot, %s points: %s"(points, stun.maxDuration));
        w.now += 21.seconds;
        foreach (_; 0 .. 20)
        {
            finisher(w, who, exposeArmor, kobold, points);
            if (target.auras.find(exposeArmor) !is null)
                break;
        }
        assert(target.auras.find(exposeArmor).amount[0] == -340 * points, format!"Expose Armor, %s points: %s"(points, target.auras.find(exposeArmor).amount[0]));
        me.player.stats.attackPower = 1000;
        foreach (_; 0 .. 20)
        {
            finisher(w, who, rupture, kobold, points);
            if (target.auras.find(rupture) !is null)
                break;
        }
        auto bleed = target.auras.find(rupture);
        assert(bleed.maxDuration == (6 + 2 * points) * 1000, "Rupture's length");
        const share = points > 3 ? 3 : points;
        assert(bleed.amount[0] == 60 + 8 * points + 10 * share, format!"Rupture, %s points: %s a tick"(points,
            bleed.amount[0]));
    }
    // The talents.
    talent(w, who, 14167);
    talent(w, who, 14176);
    talent(w, who, 14169);
    const kobold = foe(w, who, 448);
    auto target = creatureOf(w, kobold);
    me.addComboPoints(kobold, 1);
    w.now += 2.seconds;
    setPower(who, Power.energy, 100);
    assert(w.castAt(who, sliceAndDice, kobold) == SpellCastResult.ok);
    assert(me.player.auras.find(sliceAndDice).maxDuration == 9000 * 145 / 100, "Improved Slice and Dice");
    foreach (_; 0 .. 20)
    {
        w.now += 21.seconds;
        finisher(w, who, kidneyShot, kobold, 5);
        if (target.auras.find(kidneyShot) !is null)
            break;
    }
    assert(target.auras.find(kidneyShot).amount[2] == 9, "Improved Kidney Shot: 9% more damage taken");
    assert(creatureOf(w, kobold).fighter.damageTaken[0] > 1.089f && creatureOf(w, kobold).fighter.damageTaken[0] < 1.091f,
        "taken 9% more");
    foreach (_; 0 .. 20)
    {
        finisher(w, who, exposeArmor, kobold, 5);
        if (target.auras.find(exposeArmor) !is null)
            break;
    }
    assert(target.auras.find(exposeArmor).amount[0] == -1700 * 150 / 100, "Improved Expose Armor");
}

/// Riposte (14251): after a parry, not a dodge.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 403, [14251]);
    const hogger = foe(w, who, 448);
    setPower(who, Power.energy, 100);
    struck(w, who, hogger, MeleeHitOutcome.dodge);
    assert(w.castAt(who, 14251, hogger) == SpellCastResult.casterAuraState, "not after a dodge");
    struck(w, who, hogger, MeleeHitOutcome.parry);
    const r = w.castAt(who, 14251, hogger);
    assert(r == SpellCastResult.ok, format!"after a parry: %s"(r));
}

/// Hemorrhage (17348): 7 more damage from each physical blow at its target, 30 of them.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 404, [17348]);
    auto me = who.session.inWorld;
    const hogger = foe(w, who, 448);
    auto target = creatureOf(w, hogger);
    foreach (_; 0 .. 20)
    {
        setPower(who, Power.energy, 100);
        w.now += 2.seconds;
        w.castAt(who, 17348, hogger);
        if (target.auras.find(17348) !is null)
            break;
    }
    auto aura = target.auras.find(17348);
    assert(aura !is null && aura.charges == 30 && aura.amount[2] == 7);
    assert(target.fighter.damageTakenFlat[0] == 7, "7 more a blow");
    uint swings;
    landSwings(w, who, hogger, 30, () { ++swings; });
    assert(target.auras.find(17348) is null, "30 blows and gone");
}

/// Blade Flurry (13877): 20% attack speed, and each swing strikes another enemy near as well.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 405, [13877]);
    auto me = who.session.inWorld;
    const first = foe(w, who, 448), second = foe(w, who, 448);
    setPower(who, Power.energy, 100);
    assert(w.cast_(who, 13877) == SpellCastResult.ok);
    assert(me.player.auras.find(13877).amount[0] == 20);
    uint others;
    landSwings(w, who, first, 5, () {
        healFull(w, second);
        foreach (s; strikes(who))
            others += s.target == second && s.spell == 22482;
    });
    assert(others == 5, format!"each swing at the other too: %s"(others));
}

/// Whether `seen` of `n` tries fits a chance of `percent` (four standard deviations).
private bool fitsChance(uint seen, uint n, double percent)
{
    import std.math : abs, sqrt;

    const expected = n * percent / 100;
    return abs(seen - expected) <= 4 * sqrt(expected * (1 - percent / 100)) + 1;
}

/**
 * The combo point talents: Ruthlessness (14156, 14160, 14161: 20% to 60% for a point after a finishing move), Seal
 * Fate (14186...14195: 20% to 100% for another point at a crit of an ability that gives them), Relentless Strikes
 * (14179: 20% a point for 25 energy after a finishing move), Initiative (13976, 13979, 13980: 25% to 75% for another
 * point from Cheap Shot).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    uint guid = 420;
    foreach (r, rank; [14156u, 14160, 14161])
    {
        auto who = rogue(w, guid++, [eviscerate]);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        const hogger = foe(w, who, 448);
        uint points, n;
        foreach (_; 0 .. 150)
        {
            const s = finisher(w, who, eviscerate, hogger, 5);
            if (!s.damage)
                continue;
            ++n;
            points += me.comboPoints == 1 && me.comboTarget == hogger;
            me.clearComboPoints();
        }
        assert(fitsChance(points, n, 20.0 * (r + 1)), format!"Ruthlessness rank %s: %s of %s"(r + 1, points, n));
    }
    foreach (r, rank; [14186u, 14190, 14193, 14194, 14195])
    {
        if (r != 0 && r != 4)
            continue;
        auto who = rogue(w, guid++, [sinisterStrike]);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        giveAura(w, who, 1719); // crits
        const hogger = foe(w, who, 448);
        uint twice, n;
        foreach (_; 0 .. 150)
        {
            me.clearComboPoints();
            healFull(w, hogger);
            setPower(who, Power.energy, 100);
            who.read();
            w.now += 2.seconds;
            w.castAt(who, sinisterStrike, hogger);
            if (!strikes(who).canFind!(s => s.spell == sinisterStrike && s.crit))
                continue;
            ++n;
            twice += me.comboPoints == 2;
        }
        assert(n > 50 && fitsChance(twice, n, 20.0 * (r + 1)), format!"Seal Fate rank %s: %s of %s"(r + 1, twice, n));
    }
    {
        auto who = rogue(w, guid++, [eviscerate]);
        talent(w, who, 14179);
        const hogger = foe(w, who, 448);
        foreach (ubyte points; [1, 5])
        {
            uint back, n;
            foreach (_; 0 .. 150)
            {
                const s = finisher(w, who, eviscerate, hogger, points);
                if (!s.damage)
                    continue;
                ++n;
                back += energized.canFind!(e => e[0] == 14181 && e[1] == 25);
            }
            assert(fitsChance(back, n, 20.0 * points), format!"Relentless Strikes, %s points: %s of %s"(points, back, n));
        }
        auto victim = creatureOf(w, hogger);
        victim.values.set!UNIT_FIELD_MAXHEALTH(1u);
        const lethal = finisher(w, who, eviscerate, hogger, 5);
        assert(lethal.damage && !victim.alive, "Eviscerate kills the target");
        assert(energized == [[14181, 25]], "Relentless Strikes restores energy once on a lethal five-point finisher");
    }
    foreach (r, rank; [13976u, 13979, 13980])
    {
        auto who = rogue(w, guid++, [cheapShot, stealth]);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        uint three, n;
        foreach (_; 0 .. 120)
        {
            const kobold = foe(w, who, 448);
            me.clearComboPoints();
            w.now += 12.seconds;
            setPower(who, Power.energy, 100);
            me.leaveAllFights(); // (Stealth: out of combat)
            assert(w.cast_(who, stealth) == SpellCastResult.ok);
            who.read();
            w.castAt(who, cheapShot, kobold);
            if (creatureOf(w, kobold).auras.find(cheapShot) is null)
                continue;
            ++n;
            three += me.comboPoints == 3;
            creatureOf(w, kobold).values.set!UNIT_FIELD_HEALTH(0u); // (out of the way)
        }
        assert(fitsChance(three, n, 25.0 * (r + 1)), format!"Initiative rank %s: %s of %s"(r + 1, three, n));
    }
}

/**
 * Improved Kick (13754, 13867: 50% and 100% to silence 2 sec, 18425), Setup (13983, 14070, 14071: 15% to 45% for a
 * combo point at a dodge), Improved Sap (14076, 14094, 14095: 30% to 90% to stealth again after Sap), Improved Sprint
 * (13743, 13875: 50% and 100% to end the movement impairing effects as Sprint is used).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    uint guid = 440;
    foreach (r, rank; [13754u, 13867])
    {
        auto who = rogue(w, guid++, [kick]);
        talent(w, who, rank);
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        uint silenced, n;
        foreach (_; 0 .. 150)
        {
            if (auto a = target.auras.find(18425))
                target.auras.remove(a, target.values);
            healFull(w, hogger);
            setPower(who, Power.energy, 100);
            who.read();
            w.now += 11.seconds;
            w.castAt(who, kick, hogger);
            if (!strikes(who).canFind!(s => s.spell == kick && s.damage))
                continue;
            ++n;
            if (auto a = target.auras.find(18425))
            {
                ++silenced;
                assert(a.maxDuration == 2000);
            }
        }
        assert(fitsChance(silenced, n, 50.0 * (r + 1)), format!"Improved Kick rank %s: %s of %s"(r + 1, silenced, n));
    }
    foreach (r, rank; [13983u, 14070, 14071])
    {
        auto who = rogue(w, guid++, []);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        const hogger = foe(w, who, 448);
        uint points;
        enum n = 300;
        foreach (_; 0 .. n)
        {
            me.clearComboPoints();
            w.now += 1100.msecs; // past its recovery (SpellAuraOptions: 1 sec)
            struck(w, who, hogger, MeleeHitOutcome.dodge);
            points += me.comboPoints == 1 && me.comboTarget == hogger;
        }
        assert(fitsChance(points, n, 15.0 * (r + 1)), format!"Setup rank %s: %s of %s"(r + 1, points, n));
    }
    foreach (r, rank; [14076u, 14094, 14095])
    {
        auto who = rogue(w, guid++, [sap, stealth]);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        uint again, n;
        foreach (_; 0 .. 100)
        {
            const hogger = foe(w, who, 448);
            if (auto s = me.player.auras.find(stealth))
                me.removeAura(s);
            w.now += 12.seconds;
            setPower(who, Power.energy, 100);
            me.leaveAllFights(); // (Stealth: out of combat)
            assert(w.cast_(who, stealth) == SpellCastResult.ok);
            who.read();
            w.castAt(who, sap, hogger);
            if (creatureOf(w, hogger).auras.find(sap) is null)
                continue;
            ++n;
            again += me.player.auras.find(stealth) !is null;
            creatureOf(w, hogger).values.set!UNIT_FIELD_HEALTH(0u);
        }
        assert(n >= 50 && fitsChance(again, n, 30.0 * (r + 1)), format!"Improved Sap rank %s: %s of %s"(r + 1, again, n));
    }
    foreach (r, rank; [13743u, 13875])
    {
        auto who = rogue(w, guid++, [sprint]);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        uint freed;
        enum n = 100;
        foreach (_; 0 .. n)
        {
            pass(w, who, 301.seconds); // Sprint and the purge's aura run out, the cooldown with them
            giveAura(w, who, 1715); // Hamstring's slow on the rogue
            assert(me.player.auras.find(1715) !is null);
            assert(w.cast_(who, sprint) == SpellCastResult.ok);
            freed += me.player.auras.find(1715) is null;
            drop(who, 1715);
        }
        assert(fitsChance(freed, n, 50.0 * (r + 1)), format!"Improved Sprint rank %s: %s of %s"(r + 1, freed, n));
    }
}

/**
 * Remorseless Attacks (14144, 14148: 20% and 40% more crit chance for the next Sinister Strike, 20 sec, 14143 and 14149)
 * after a kill that yields experience; not after a grey one.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (r, rank; [14144u, 14148])
    {
        auto who = w.character(460 + cast(uint) r, format!"Remorse%s"(r), PlayerClass.rogue, 5, []);
        auto me = who.session.inWorld;
        talent(w, who, rank);
        const effect = r ? 14149 : 14143;
        // A kobold (level 1 or 2) is worth experience at level 5, not at 60.
        const kobold = foe(w, who);
        auto target = creatureOf(w, kobold);
        while (target.alive)
            me.swing(target, AttackType.mainHand);
        auto aura = me.player.auras.find(effect);
        assert(aura !is null && aura.maxDuration == 20_000 && aura.amount[0] == 20 * (r + 1),
            format!"rank %s after a kill"(r + 1));
    }
    auto grey = w.character(462, "Grey", PlayerClass.rogue, 60, []);
    talent(w, grey, 14148);
    const kobold = foe(w, grey);
    auto target = creatureOf(w, kobold);
    while (target.alive)
        grey.session.inWorld.swing(target, AttackType.mainHand);
    assert(grey.session.inWorld.player.auras.find(14149) is null, "not after a grey kill");
}

/**
 * The rogue's weapon specializations: Sword Specialization (13960...13964: 1% to 5% for an extra attack) and Mace
 * Specialization (13709, 13800...13803: 1% to 6% to stun 3 sec, and 5 more mace skill).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 470, [], wornShortsword);
    auto me = who.session.inWorld;
    giveAura(w, who, 13964);
    const hogger = foe(w, who, 448);
    uint extra;
    enum n = 1000;
    landSwings(w, who, hogger, n, () {
        extra += me.extraAttacks != 0;
        me.extraAttacks = 0;
    });
    assert(fitsChance(extra, n, 5), format!"Sword Specialization: %s of %s"(extra, n));

    auto maceman = rogue(w, 471, [], wornMace);
    const skill = maceman.session.inWorld.player.fighter.weaponSkill[0];
    talent(w, maceman, 13803);
    maceman.session.inWorld.player.refreshChances(w.context.data);
    assert(maceman.session.inWorld.player.fighter.weaponSkill[0] == skill + 5, format!"5 more mace skill: %s, %s"(skill, maceman.session.inWorld.player.fighter.weaponSkill[0]));
    const kobold = foe(w, maceman, 448);
    auto target = creatureOf(w, kobold);
    uint stuns;
    landSwings(w, maceman, kobold, n, () {
        if (auto stun = target.auras.find(5530))
        {
            ++stuns;
            target.auras.remove(stun, target.values);
        }
    });
    assert(fitsChance(stuns, n, 6), format!"Mace Specialization: %s of %s"(stuns, n));
}

/**
 * Camouflage (14065: 15% more speed in Stealth, 5 sec less of its cooldown) and Improved Poisons (14117: 10% more
 * chance for Instant Poison VI, 625, on a swing: 20% and 10).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = rogue(w, 480, [stealth]);
    auto me = who.session.inWorld;
    assert(w.cast_(who, stealth) == SpellCastResult.ok);
    const plain = me.player.auras.find(stealth).amount[1];
    me.removeAura(me.player.auras.find(stealth));
    w.now += 11.seconds;
    talent(w, who, 14065);
    assert(w.cast_(who, stealth) == SpellCastResult.ok);
    assert(me.player.auras.find(stealth).amount[1] == plain + 15, format!"%s, %s"(plain, me.player.auras.find(stealth).amount[1]));
    me.removeAura(me.player.auras.find(stealth));
    w.now += 5100.msecs;
    assert(me.spellIsReady(stealth), "ready 5 sec after, not 10");

    // Improved Poisons.
    foreach (r, rank; [0u, 14117])
    {
        auto poisoner = rogue(w, 481 + cast(uint) r, []);
        auto p = poisoner.session.inWorld;
        if (rank)
            talent(w, poisoner, rank);
        p.setEnchantment(cast() p.player.inventory.equipped(15), 1, 625, 1_800_000);
        const hogger = foe(w, poisoner, 448);
        uint poisoned;
        enum n = 600;
        landSwings(w, poisoner, hogger, n, () {
            foreach (s; strikes(poisoner))
                poisoned += s.spell == 11337;
        });
        assert(fitsChance(poisoned, n, rank ? 30 : 20), format!"Instant Poison VI: %s of %s"(poisoned, n));
    }
}

/// Serrated Blades (14171, 14172, 14173): 100, 200, 300 of the target's armor ignored at level 60, by every blow.
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.combat : armorAgainst;

    auto w = RealWorld.make();
    foreach (r, rank; [14171u, 14172, 14173])
    {
        auto who = rogue(w, 490 + cast(uint) r, []);
        auto me = who.session.inWorld;
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        const before = armorAgainst(me.player.fighter, target.fighter);
        talent(w, who, rank);
        const ignored = 100 * (r + 1);
        assert(me.player.fighter.armorIgnored >= ignored - 1 && me.player.fighter.armorIgnored <= ignored + 1,
            format!"rank %s: %s armor ignored"(r + 1, me.player.fighter.armorIgnored));
        const after = armorAgainst(me.player.fighter, target.fighter);
        assert(after == (before > me.player.fighter.armorIgnored ? before - me.player.fighter.armorIgnored : 0));
    }
}

// ---------------------------------------------------------------------------
// Hunter
// ---------------------------------------------------------------------------

enum uint wornShortbow = 2504, roughArrow = 2512, concussiveShot = 5116, wingClip = 14268, counterattack = 20910,
    mongooseBite = 14271, raptorStrike = 14266, cheetah = 5118, pack = 13159, hawk = 14322, wyvernSting = 24133,
    scareBeast = 14327, arcaneShot = 14287;

/// A hunter of `guid` with a sword in hand and a bow, arrows in its bags, knowing `spells`.
private TestClient hunter(ref RealWorld w, uint guid, const(uint)[] spells)
{
    import dmangos.world.testdata : raceOrc;

    auto who = w.character(guid, format!"Hunter%s"(guid), PlayerClass.hunter, 60, spells, raceOrc); // (no human hunter)
    equip(who, wornShortsword);
    equip(who, wornShortbow);
    foreach (_; 0 .. 5)
        who.session.inWorld.storeLoot(roughArrow, 200, 0, false);
    who.session.inWorld.player.data.ammoId = roughArrow; // (what the stats put back in PLAYER_AMMO_ID)
    who.session.inWorld.player.values.set!PLAYER_AMMO_ID(roughArrow);
    who.read();
    return who;
}

/// A single-charge Furious Howl adds its full physical amount to Heroic Strike and Raptor Strike once.
unittest
{
    if (!haveRealData())
        return;
    enum uint heroicStrike = 11567, howlRankFour = 24597;
    foreach (id; [heroicStrike, raptorStrike])
    {
        auto w = RealWorld.make();
        auto who = id == raptorStrike ? hunter(w, 520, [id])
            : w.character(520, "Howler", PlayerClass.warrior, 60, [id]);
        if (id == heroicStrike)
            equip(who, wornShortsword);
        auto me = who.session.inWorld;
        auto target = creatureOf(w, foe(w, who, 448));
        target.values.set!UNIT_FIELD_RESISTANCES(0, 0);
        auto map = w.context.map(0);

        Strike swingWith(uint seed)
        {
            w.now += 10.seconds; // both the global cooldown and Raptor Strike's cooldown
            if (id == heroicStrike)
                setPower(who, Power.rage, 1000);
            else
                setPower(who, Power.mana, me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana));
            who.read();
            map.random.seed(seed);
            const result = w.castAt(who, id, target.guid);
            assert(result == SpellCastResult.ok, format!"queueing weapon attack %s: %s"(id, result));
            me.swing(target, AttackType.mainHand);
            foreach (hit; strikes(who))
                if (hit.spell == id && hit.target == target.guid)
                    return hit;
            return Strike.init;
        }

        uint seed = 20_261_123;
        Strike original;
        foreach (_; 0 .. 20)
        {
            original = swingWith(seed);
            if (original.damage && !original.crit)
                break;
            ++seed;
        }
        assert(original.damage && !original.crit, "a repeatable noncritical hit landed");
        const extra = giveAura(w, who, howlRankFour).amount[0];
        assert(extra >= 45 && extra <= 57, "rank four Furious Howl amount comes from the real spell data");
        const boosted = swingWith(seed);
        assert(boosted.damage == original.damage + extra, format!"spell %s deals %s plus %s: observed %s"(
            id, original.damage, extra, boosted.damage));
        assert(me.player.auras.find(howlRankFour) is null, "the next physical attack spends Furious Howl");
        assert(swingWith(seed).damage == original.damage, "the following attack uses unbuffed weapon damage");
    }
}

/**
 * Counterattack (20910): after a parry only; Mongoose Bite (14271): after a dodge only. Savage Strikes (19160: 20%
 * more crit chance) on Raptor Strike (14266).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = hunter(w, 500, [counterattack, mongooseBite, raptorStrike]);
    const hogger = foe(w, who, 448);
    setPower(who, Power.mana, 5000);
    assert(w.castAt(who, counterattack, hogger) == SpellCastResult.casterAuraState, "Counterattack: not before");
    assert(w.castAt(who, mongooseBite, hogger) == SpellCastResult.casterAuraState, "Mongoose Bite: not before");
    struck(w, who, hogger, MeleeHitOutcome.parry);
    assert(w.castAt(who, mongooseBite, hogger) == SpellCastResult.casterAuraState, "Mongoose Bite: not after a parry");
    {
        const r = w.castAt(who, counterattack, hogger);
        assert(r == SpellCastResult.ok, format!"Counterattack after a parry: %s"(r));
    }
    who.session.inWorld.updateReactives(5000);
    struck(w, who, hogger, MeleeHitOutcome.dodge);
    w.now += 6.seconds;
    assert(w.castAt(who, counterattack, hogger) == SpellCastResult.casterAuraState, "Counterattack: not after a dodge");
    {
        const r = w.castAt(who, mongooseBite, hogger);
        assert(r == SpellCastResult.ok, format!"Mongoose Bite after a dodge: %s"(r));
    }
    // Savage Strikes: Raptor Strike's crits, about a fifth more often.
    uint crits(uint tries)
    {
        uint n;
        foreach (_; 0 .. tries)
        {
            healFull(w, hogger);
            setPower(who, Power.mana, 5000);
            who.read();
            w.now += 7.seconds;
            w.castAt(who, raptorStrike, hogger); // (on the next swing)
            who.session.inWorld.swing(creatureOf(w, hogger), AttackType.mainHand);
            foreach (s; strikes(who))
                n += s.spell == raptorStrike && s.crit;
        }
        return n;
    }
    const plain = crits(600);
    talent(w, who, 19160);
    const savage = crits(600);
    assert(savage >= plain + 60, format!"Savage Strikes: %s crits against %s"(savage, plain)); // (120 expected)
}

/**
 * Improved Concussive Shot (19407, 19412...19415: 4% to 20% to stun 3 sec, 19410) and Improved Wing Clip (19228,
 * 19232...19235: 4% to 20% to root 5 sec, 19229), of their own ability only.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    struct Row
    {
        uint rank, percent, ability, effect, duration;
    }
    const rows = [Row(19407, 4, concussiveShot, 19410, 3000), Row(19415, 20, concussiveShot, 19410, 3000),
        Row(19228, 4, wingClip, 19229, 5000), Row(19235, 20, wingClip, 19229, 5000)];
    uint guid = 510;
    foreach (row; rows)
    {
        auto who = hunter(w, guid++, [row.ability]);
        talent(w, who, row.rank);
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        if (row.ability == concussiveShot) // at range
            target.movement.position.x += 10;
        uint landed, procced;
        foreach (_; 0 .. 500)
        {
            foreach (a; target.auras.list.dup)
                if (a.spell.id == row.effect || a.spell.id == row.ability)
                {
                    if (a.spell.id == row.effect)
                        assert(a.maxDuration == row.duration, format!"%s lasts %s"(row.effect, a.maxDuration));
                    target.auras.remove(a, target.values);
                }
            healFull(w, hogger);
            setPower(who, Power.mana, 5000);
            who.read();
            w.now += 13.seconds;
            w.castAt(who, row.ability, hogger);
            w.now += 1.seconds; // its flight (the creature's map not run: it would close in)
            who.session.inWorld.update(1.seconds);
            if (target.auras.find(row.ability) is null)
                continue;
            ++landed;
            procced += target.auras.find(row.effect) !is null;
        }
        assert(landed > 150 && fitsChance(procced, landed, row.percent),
            format!"%s: %s of %s, not %s%%"(row.rank, procced, landed, row.percent));
    }
}

/**
 * Aspect of the Cheetah (5118: 30% faster, dazed 4 sec when struck, 15571) and Aspect of the Pack (13159); Pathfinding
 * (19560: 6% more speed for both).
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (k, aspect; [cheetah, pack])
    {
        auto who = hunter(w, 520 + cast(uint) k, [aspect]);
        auto me = who.session.inWorld;
        setPower(who, Power.mana, 5000);
        assert(w.cast_(who, aspect) == SpellCastResult.ok);
        assert(me.player.auras.find(aspect).amount[0] == 30);
        const hogger = foe(w, who, 448);
        struck(w, who, hogger, MeleeHitOutcome.normal);
        auto daze = me.player.auras.find(15571);
        assert(daze !is null && daze.maxDuration == 4000, "dazed when struck");
        me.removeAura(me.player.auras.find(aspect));
        talent(w, who, 19560);
        w.now += 2.seconds;
        assert(w.cast_(who, aspect) == SpellCastResult.ok);
        assert(me.player.auras.find(aspect).amount[0] == 36, format!"Pathfinding: %s"(me.player.auras.find(aspect).amount[0]));
    }
}

/**
 * Wyvern Sting (24133): asleep 12 sec, any damage wakes it; as it wakes, 600 nature damage over 12 sec (24135).
 * Scare Beast (14327): a beast flees 20 sec; damage may end it.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = hunter(w, 530, [wyvernSting, arcaneShot]);
    auto me = who.session.inWorld;
    const hogger = foe(w, who, 448);
    auto target = creatureOf(w, hogger);
    target.movement.position.x += 10;
    setPower(who, Power.mana, 5000);
    bool slept;
    foreach (_; 0 .. 20)
    {
        w.now += 121.seconds;
        me.leaveAllFights();
        w.castAt(who, wyvernSting, hogger);
        w.now += 1.seconds; // its flight
        me.update(1.seconds);
        if (target.auras.find(wyvernSting) !is null)
        {
            slept = true;
            break;
        }
    }
    assert(slept);
    assert(target.auras.find(wyvernSting).maxDuration == 12_000, "12 sec asleep");
    w.now += 2.seconds;
    foreach (_; 0 .. 20)
    {
        w.castAt(who, arcaneShot, hogger);
        w.now += 1.seconds;
        me.update(1.seconds);
        if (target.auras.find(wyvernSting) is null)
            break;
        w.now += 7.seconds;
    }
    assert(target.auras.find(wyvernSting) is null, "damage wakes it");
    auto poison = target.auras.find(24135);
    assert(poison !is null && poison.maxDuration == 12_000, "the poison as it wakes");
    // 600 over its ticks.
    int total;
    foreach (i; 0 .. 3)
        if (poison.amount[i] > 0 && poison.spell.casting.amplitude[i] > 0)
            total += poison.amount[i] * (12_000 / poison.spell.casting.amplitude[i]);
    assert(total == 600, format!"600 nature damage: %s"(total));
}

/**
 * Improved Aspect of the Hawk (19552...19556: 1% to 5%) while Aspect of the Hawk (14322) is on: a normal ranged
 * attack (Auto Shot) gives Quick Shots (6150: 30% ranged attack speed, 12 sec); none without the talent.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (k, rank; [0u, 19556])
    {
        auto who = hunter(w, 540 + cast(uint) k, [hawk, 75]);
        auto me = who.session.inWorld;
        if (rank)
            talent(w, who, rank);
        setPower(who, Power.mana, 5000);
        assert(w.cast_(who, hawk) == SpellCastResult.ok);
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        uint shots, quick;
        foreach (_; 0 .. 600)
        {
            target.movement.position = me.player.position;
            target.movement.position.x += 15; // at range
            healFull(w, hogger);
            who.read();
            me.player.values.set!UNIT_FIELD_TARGET(hogger); // (what the repeats shoot at)
            w.castAt(who, 75, hogger);
            foreach (step; 0 .. 4)
            {
                w.now += 1.seconds;
                me.update(1.seconds);
            }
            if (!strikes(who).canFind!(s => s.spell == 75 && s.damage))
                continue;
            ++shots;
            if (auto q = me.player.auras.find(6150))
            {
                ++quick;
                assert(q.amount[0] == 30 && q.maxDuration == 12_000);
                me.removeAura(q);
            }
        }
        assert(shots > 200, format!"%s shots"(shots));
        assert(rank ? fitsChance(quick, shots, 5) : quick == 0, format!"Quick Shots: %s of %s"(quick, shots));
    }
}

/// Entrapment (19184, 19387...19390: 5% to 25%): a trap's effect (Immolation Trap's, 14301) roots its target 5 sec
/// (19185).
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (k, rank; [19184u, 19390])
    {
        auto who = hunter(w, 550 + cast(uint) k, [14301]);
        talent(w, who, rank);
        const hogger = foe(w, who, 448);
        auto target = creatureOf(w, hogger);
        uint rooted, n;
        foreach (_; 0 .. 400)
        {
            foreach (a; target.auras.list.dup)
                if (a.spell.id == 19185 || a.spell.id == 14301)
                    target.auras.remove(a, target.values);
            w.now += 2.seconds;
            w.castAt(who, 14301, hogger); // the trap's effect, as the trap casts it
            if (target.auras.find(14301) is null)
                continue;
            ++n;
            if (auto root = target.auras.find(19185))
            {
                ++rooted;
                assert(root.maxDuration == 5000);
            }
        }
        assert(n > 200 && fitsChance(rooted, n, k ? 25 : 5), format!"Entrapment: %s of %s"(rooted, n));
    }
}
