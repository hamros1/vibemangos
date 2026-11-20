/**
 * The warlock's and the hunter's pet talents, tested on the real data (`dmangos.world.realspelltests`): each by what
 * its 1.12.1 tooltip claims, on a demon summoned or a beast tamed (`dmangos.world.petauras` gives a pet its passive
 * auras and its owner's talents' share; `dmangos.world.creatureprocs` its procs).
 */
module dmangos.world.realclass_pets;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import std.math : isClose, round;
import dmangos.bytes : ByteReader;
import dmangos.world.auras : Aura, AuraType, makeAura;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.movement : MoveType;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : SpellTargets, TargetFlags;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient;
import dmangos.world.testdata : raceOrc;
private enum ubyte raceDwarf = 3; // (an Alliance hunter: Stormwind's guards leave its pet alone)
import dmangos.world.updatefields;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private enum ubyte classWarlock = 9, classHunter = 3;
private enum uint summonImp = 688, summonVoidwalker = 697, summonSuccubus = 712, summonFelhunter = 691;
private enum uint stonetuskBoar = 113;

/// The real spell `id`.
private const(SpellInfo)* spellOf(ref RealWorld w, uint id)
{
    const s = w.context.data.spells.spell(id);
    assert(s !is null, format!"no spell %s"(id));
    return s;
}

/// Time passes: for the character and its map.
private void pass(ref RealWorld w, ref TestClient who, Duration elapsed)
{
    w.now += elapsed;
    who.session.inWorld.update(elapsed);
    w.context.map(0).update(elapsed);
}

/// Time passes in steps of a tenth of a second (a pet's swings, its owner's area auras).
private void passSteps(ref RealWorld w, ref TestClient who, Duration elapsed)
{
    for (auto left = elapsed; left > Duration.zero; left -= 100.msecs)
        pass(w, who, 100.msecs);
}

/// A level 60 warlock (`guid`), with the demon of `summon` out.
private Creature warlockWith(ref RealWorld w, ref TestClient who, uint summon)
{
    auto me = who.session.inWorld;
    me.castSpell(spellOf(w, summon), SpellTargets(TargetFlags.self, 0), true, 0);
    who.read();
    auto pet = me.ownPet;
    assert(pet !is null && pet.alive, format!"no demon of %s"(summon));
    pass(w, who, 100.msecs);
    return pet;
}

/// A level 60 hunter's pet: a Stonetusk Boar tamed.
private Creature tamed(ref RealWorld w, ref TestClient who)
{
    auto me = who.session.inWorld;
    auto at = me.player.position;
    at.y -= 3;
    auto beast = w.context.summonCreature(w.context.map(0), stonetuskBoar, at, TempSpawnType.manual, 0, 0);
    me.tameBeastChannelDone(beast.guid);
    who.read();
    auto pet = me.ownPet;
    assert(pet !is null && pet.alive, "no beast tamed");
    pass(w, who, 100.msecs);
    return pet;
}

/// The talent (a rank of one) learned: its passive aura on the owner; the pet's stats follow at its next tick.
private void talent(ref RealWorld w, ref TestClient who, uint id)
{
    auto me = who.session.inWorld;
    me.applyPassive(spellOf(w, id));
    assert(me.player.auras.find(id) !is null, format!"talent %s on"(id));
    pass(w, who, 100.msecs);
}

/// The aura of `id` off the character.
private void drop(ref RealWorld w, ref TestClient who, uint id)
{
    auto me = who.session.inWorld;
    while (auto aura = me.player.auras.find(id))
        me.removeAura(aura);
    pass(w, who, 100.msecs);
}

/// A kobold in front of `who` with health enough for a test's blows, its creature.
private Creature foe(ref RealWorld w, ref TestClient who)
{
    who.session.inWorld.player.movement.position.orientation = 0;
    auto c = cast(Creature) w.context.map(0).findObject(w.enemy(who));
    c.values.set!UNIT_FIELD_MAXHEALTH(1_000_000u);
    c.values.set!UNIT_FIELD_HEALTH(1_000_000u);
    return c;
}

/// `pet` casts `spell` at `target` as its owner tells it to; whether it did.
private bool petCasts(ref RealWorld w, Creature pet, uint spell, ulong target)
{
    pet.ai.petCooldowns = null;
    pet.ai.petCategoryCooldowns = null;
    pet.values.set!UNIT_FIELD_POWER1(0, pet.values.get!UNIT_FIELD_MAXPOWER1(0));
    return pet.ai.petCastByCommand(spellOf(w, spell), target, w.context.map(0));
}

/// The spell damage logs of `spell` since the last read: the damage of each.
private uint[] damageLogs(ref TestClient who, uint spell)
{
    uint[] logs;
    foreach (p; who.read())
        if (p.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            if (r.read!uint == spell)
                logs ~= r.read!uint;
        }
    return logs;
}

/// The periodic aura logs of `spell` about `target` since the last read: the amount of each.
private uint[] periodicLogs(ref TestClient who, ulong target, uint spell)
{
    uint[] logs;
    foreach (p; who.read())
        if (p.opcode == Opcode.SMSG_PERIODICAURALOG)
        {
            auto r = ByteReader(p.body_);
            if (r.readPackedGuid() != target)
                continue;
            r.readPackedGuid();
            if (r.read!uint != spell)
                continue;
            r.read!uint;
            r.read!uint;
            logs ~= r.read!uint;
        }
    return logs;
}

/// `who` takes the item `entry` and puts it on.
private void equip(ref TestClient who, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    auto me = who.session.inWorld;
    foreach (skill; [45u, 46, 226]) // bows, guns, crossbows
        me.player.setSkill(skill, 300, 300);
    me.player.refreshChances(me.context.data);
    me.storeLoot(entry, 1, 0, false);
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
            {
                who.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, s));
                break;
            }
    who.read();
}

/// What a pet's stat field reads, rounded as the pet's stats are.
private uint scaled(uint value, double factor)
{
    return cast(uint) round(value * factor);
}

// ---------------------------------------------------------------------------
// The groundwork
// ---------------------------------------------------------------------------

/**
 * A pet's passive auras are its family's (`CreatureFamily.dbc`, `SkillLineAbility.dbc`): a tamed beast's "Tamed Pet
 * Passive" 8875, 19580 .. 19591, 20784, and its family's own (a boar's 7000); an imp's 18728, 18737, 18740. Without
 * talents, the first change nothing; an orc's Command ("Damage dealt by Hunter and Warlock pets increased by 5%")
 * adds to 8875.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto hunter = w.character(1, "Rexxar", classHunter, 60, [], raceOrc);
    auto beast = tamed(w, hunter);
    foreach (id; [8875, 19580, 19581, 19582, 19589, 19591, 20784])
        assert(beast.auras.find(id) !is null, format!"the beast's passive %s"(id));
    foreach (id; [19580, 19581, 19582, 19589, 19591, 20784])
        assert(beast.auras.find(id).amount[0] == 0, "nothing without the hunter's talents");
    // The boar's own (7000: 10% less physical damage, 9% more armor, 4% more health), in its stats.
    const base = beast.petData.base;
    assert(beast.values.get!UNIT_FIELD_MAXHEALTH == scaled(base.health, 1.04)
        && beast.values.get!UNIT_FIELD_RESISTANCES(0) == scaled(base.armor, 1.09), "a boar's tougher");
    assert(isClose(beast.fighter.damageDone[0], 0.9f * 1.05f), "and weaker, but for its orc hunter's Command (5% more)");
    auto warlock = w.character(2, "Gul'dan", classWarlock, 60, []);
    auto imp = warlockWith(w, warlock, summonImp);
    foreach (id; [18728, 18737, 18740])
        assert(imp.auras.find(id) !is null, format!"the imp's passive %s"(id));
}

// ---------------------------------------------------------------------------
// Warlock
// ---------------------------------------------------------------------------

/// Fel Stamina (18748 .. 18752): "Increases the maximum Health of your Imp, Voidwalker, Succubus, and Felhunter by 15%";
/// Fel Intellect (18731, 18743 .. 18746): "... maximum Mana ... by 15%". 3% a rank.
unittest
{
    if (!haveRealData())
        return;
    foreach (summon; [summonImp, summonVoidwalker, summonSuccubus, summonFelhunter])
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        auto demon = warlockWith(w, warlock, summon);
        const health = demon.values.get!UNIT_FIELD_MAXHEALTH, mana = demon.values.get!UNIT_FIELD_MAXPOWER1(0);
        foreach (rank, ids; [[18748u, 18731], [18749u, 18743], [18750u, 18744], [18751u, 18745], [18752u, 18746]])
        {
            talent(w, warlock, ids[0]);
            talent(w, warlock, ids[1]);
            const factor = 1 + 0.03 * (rank + 1);
            assert(demon.values.get!UNIT_FIELD_MAXHEALTH == scaled(health, factor), format!"Fel Stamina %s on %s: %s of %s"(
                rank + 1, summon, demon.values.get!UNIT_FIELD_MAXHEALTH, health));
            assert(demon.values.get!UNIT_FIELD_MAXPOWER1(0) == scaled(mana, factor), format!"Fel Intellect %s on %s"(
                rank + 1, summon));
            assert(demon.values.get!UNIT_FIELD_HEALTH == demon.values.get!UNIT_FIELD_MAXHEALTH, "a full demon stays full");
            drop(w, warlock, ids[0]);
            drop(w, warlock, ids[1]);
        }
        assert(demon.values.get!UNIT_FIELD_MAXHEALTH == health, "and back without them");
    }
}

/// Unholy Power (18769 .. 18773): "Increases the damage done by your Voidwalker, Succubus, and Felhunter's melee
/// attacks by 20%", 4% a rank.
unittest
{
    if (!haveRealData())
        return;
    foreach (summon; [summonVoidwalker, summonSuccubus, summonFelhunter])
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        auto demon = warlockWith(w, warlock, summon);
        assert(isClose(demon.fighter.damageDone[0], 1.0f));
        foreach (rank, id; [18769u, 18770, 18771, 18772, 18773])
        {
            talent(w, warlock, id);
            assert(isClose(demon.fighter.damageDone[0], 1 + 0.04f * (rank + 1)), format!"Unholy Power %s: %s"(rank + 1,
                demon.fighter.damageDone[0]));
            drop(w, warlock, id);
        }
    }
}

/**
 * Improved Imp (18694 .. 18696): "Increases the effect of your Imp's Firebolt, Fire Shield, and Blood Pact spells by
 * 30%". The Imp casts Fire Shield on its warlock and Blood Pact (given to the warlock as its party): their amounts;
 * Firebolt's damage at a kobold, within its range made 30% more.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint fireShield = 2947, bloodPact = 6307, firebolt = 3110;
    int[2] shield, pact;
    uint[][2] bolts;
    foreach (with_; 0 .. 2)
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        auto me = warlock.session.inWorld;
        if (with_)
            talent(w, warlock, 18696);
        auto imp = warlockWith(w, warlock, summonImp);
        assert(petCasts(w, imp, fireShield, me.player.guid), "Fire Shield");
        assert(petCasts(w, imp, bloodPact, imp.guid), "Blood Pact");
        pass(w, warlock, 1100.msecs); // its party gets Blood Pact at the next second
        const s = me.player.auras.find(fireShield), p = me.player.auras.find(bloodPact);
        assert(s !is null && p !is null, "Fire Shield and Blood Pact on the warlock");
        shield[with_] = s.amount[0];
        pact[with_] = p.amount[0];
        assert(imp.auras.find(bloodPact).amount[0] == pact[with_], "the imp's own the same");
        auto kobold = foe(w, warlock);
        warlock.read();
        foreach (_; 0 .. 600)
        {
            if (!imp.ai.castingNow)
                petCasts(w, imp, firebolt, kobold.guid);
            pass(w, warlock, 100.msecs);
            bolts[with_] ~= damageLogs(warlock, firebolt);
            if (bolts[with_].length >= 3)
                break;
        }
        assert(bolts[with_].length >= 3, format!"Firebolts landed: %s %s %s"(bolts[with_], imp.ai.castRefusal, imp.alive));
    }
    assert(shield[1] == cast(int)(shield[0] * 1.3) && pact[1] == cast(int)(pact[0] * 1.3), format!"30%%: %s %s"(shield, pact));
    // Firebolt's damage: a roll within its range; with the talent, the range is 30% higher (a kobold resists no fire).
    import std.algorithm.searching : maxElement, minElement;

    assert(bolts[1].minElement > bolts[0].minElement && bolts[1].maxElement > bolts[0].maxElement,
        format!"Firebolt %s, %s"(bolts[0], bolts[1]));
}

/// Improved Firebolt (18126, 18127): "Reduces the casting time of your Imp's Firebolt spell by 1 sec" (0.5 a rank).
unittest
{
    if (!haveRealData())
        return;
    enum uint firebolt = 3110;
    uint castMs(uint rank)
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        if (rank)
            talent(w, warlock, rank);
        auto imp = warlockWith(w, warlock, summonImp);
        auto kobold = foe(w, warlock);
        warlock.read();
        assert(petCasts(w, imp, firebolt, kobold.guid), "Firebolt cast");
        foreach (p; warlock.read())
            if (p.opcode == Opcode.SMSG_SPELL_START)
            {
                auto r = ByteReader(p.body_);
                r.readPackedGuid();
                r.readPackedGuid();
                if (r.read!uint != firebolt)
                    continue;
                r.read!ushort;
                return r.read!uint;
            }
        assert(false, "no Firebolt started");
    }
    const plain = castMs(0);
    assert(castMs(18126) == plain - 500 && castMs(18127) == plain - 1000, format!"Firebolt's %s ms"(plain));
}

/// Improved Lash of Pain (18128, 18129): "Reduces the cooldown of your Succubus' Lash of Pain spell by 6 sec" (3 a rank).
unittest
{
    if (!haveRealData())
        return;
    enum uint lashOfPain = 7814;
    int cooldown(uint rank)
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        if (rank)
            talent(w, warlock, rank);
        auto succubus = warlockWith(w, warlock, summonSuccubus);
        auto kobold = foe(w, warlock);
        assert(petCasts(w, succubus, lashOfPain, kobold.guid), "Lash of Pain");
        return succubus.ai.petCategoryCooldowns.get(spellOf(w, lashOfPain).category, 0);
    }
    const plain = cooldown(0);
    assert(plain == 12_000 && cooldown(18128) == 9_000 && cooldown(18129) == 6_000);
}

/**
 * Improved Succubus (18754 .. 18756): "Increases the effect of your Succubus' Lash of Pain and Soothing Kiss spells by
 * 30%, and increases the duration of your Succubus' Seduction and Lesser Invisibility spells by 30%": the durations
 * of the auras, and the values of Lash of Pain and Soothing Kiss as the succubus casts them.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint seduction = 6358, lesserInvisibility = 7870, lashOfPain = 7814, soothingKiss = 6360;
    int[2] seduced, invisible, lash, kiss;
    foreach (with_; 0 .. 2)
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        auto me = warlock.session.inWorld;
        if (with_)
            talent(w, warlock, 18756);
        auto succubus = warlockWith(w, warlock, summonSuccubus);
        assert(petCasts(w, succubus, lesserInvisibility, succubus.guid));
        invisible[with_] = succubus.auras.find(lesserInvisibility).maxDuration;
        succubus.loseAura(succubus.auras.find(lesserInvisibility), w.context.map(0));
        auto kobold = foe(w, warlock);
        succubus.ai.react = imported!"dmangos.world.creatureai".ReactState.passive; // (her blows would wake it)
        foreach (_; 0 .. 400)
        {
            if (!succubus.ai.castingNow)
                petCasts(w, succubus, seduction, kobold.guid);
            pass(w, warlock, 100.msecs);
            if (auto aura = kobold.auras.find(seduction))
            {
                seduced[with_] = aura.maxDuration;
                break;
            }
        }
        assert(seduced[with_] > 0, "Seduction landed");
        lash[with_] = me.petEffectMod(spellOf(w, lashOfPain), 0, 1000, succubus);
        kiss[with_] = me.petEffectMod(spellOf(w, soothingKiss), 0, -1000, succubus);
    }
    assert(invisible[1] == cast(int)(invisible[0] * 1.3) && seduced[1] == cast(int)(seduced[0] * 1.3),
        format!"durations %s %s"(invisible, seduced));
    assert(lash == [1000, 1300] && kiss == [-1000, -1300], format!"%s %s"(lash, kiss));
}

/**
 * Improved Voidwalker (18705 .. 18707): "Increases the effectiveness of your Voidwalker's Torment, Consume Shadows,
 * Sacrifice and Suffering spells by 30%": Torment's threat on a kobold, Consume Shadows' heal, Sacrifice's shield on the
 * warlock (the voidwalker dies of it).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint torment = 7809, consumeShadows = 17767, sacrifice = 7812;
    float[2] threat;
    int[2] heal, shield;
    foreach (with_; 0 .. 2)
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        auto me = warlock.session.inWorld;
        if (with_)
            talent(w, warlock, 18707);
        auto voidwalker = warlockWith(w, warlock, summonVoidwalker);
        auto kobold = foe(w, warlock);
        assert(petCasts(w, voidwalker, torment, kobold.guid), "Torment");
        threat[with_] = kobold.ai.threatOf(voidwalker.guid);
        assert(petCasts(w, voidwalker, consumeShadows, voidwalker.guid), "Consume Shadows");
        heal[with_] = voidwalker.auras.find(consumeShadows).amount[0];
        assert(petCasts(w, voidwalker, sacrifice, voidwalker.guid), "Sacrifice");
        auto aura = me.player.auras.find(sacrifice);
        assert(aura !is null && !voidwalker.alive, "the warlock shielded, the voidwalker gone");
        shield[with_] = aura.amount[0];
    }
    assert(threat[0] > 0 && isClose(threat[1], cast(int)(threat[0] * 1.3)), format!"Torment %s"(threat));
    assert(heal[1] == cast(int)(heal[0] * 1.3) && shield[1] == cast(int)(shield[0] * 1.3), format!"%s %s"(heal, shield));
}

/**
 * Master Demonologist (23785, 23822 .. 23825): "Grants both the Warlock and the summoned demon an effect as long as
 * that demon is active. Imp - Reduces threat caused by 20%. Voidwalker - Reduces physical damage taken by 10%.
 * Succubus - Increases all damage caused by 10%. Felhunter - Increases all resistances by 1 per level." Rank 5's: the
 * demon's aura (`spell_pet_auras`) and its copy on the warlock (`SPELL_EFFECT_APPLY_AREA_AURA_PET`), gone with it.
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (summon; [summonImp, summonVoidwalker, summonSuccubus, summonFelhunter])
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, []);
        auto me = warlock.session.inWorld;
        talent(w, warlock, 23825);
        const shadowBefore = me.player.values.get!UNIT_FIELD_RESISTANCES(5);
        auto demon = warlockWith(w, warlock, summon);
        pass(w, warlock, 1.seconds); // the warlock's copy at the next second
        const f = me.player.fighter, d = demon.fighter;
        switch (summon)
        {
        case summonImp:
            assert(isClose(me.player.damageMods.threat[0], 0.8f) && isClose(me.player.damageMods.threat[4], 0.8f),
                "Imp: 20% less threat");
            assert(demon.auras.find(23829) !is null);
            break;
        case summonVoidwalker:
            assert(isClose(f.damageTaken[0], 0.9f) && isClose(d.damageTaken[0], 0.9f) && isClose(f.damageTaken[5], 1),
                "Voidwalker: 10% less physical damage taken, both");
            break;
        case summonSuccubus:
            assert(isClose(f.damageDone[0], 1.1f) && isClose(d.damageDone[0], 1.1f)
                && isClose(me.player.damageMods.school[5], 1.1f), "Succubus: 10% more damage, both");
            break;
        default:
            assert(me.player.values.get!UNIT_FIELD_RESISTANCES(5) == shadowBefore + 60
                && demon.values.get!UNIT_FIELD_RESISTANCES(5) >= 60, "Felhunter: 60 more at level 60, both");
            break;
        }
        me.unsummonPet(0);
        pass(w, warlock, 1.seconds);
        foreach (id; [23829u, 23840, 23844, 23836])
            assert(me.player.auras.find(id) is null, "gone with its demon");
    }
}

/**
 * Soul Link (19028): "When active, 30% of all damage taken by the caster is taken by your Imp, Voidwalker, Succubus,
 * or Felhunter demon instead. In addition, both the demon and master will inflict 3% more damage. Lasts as long as the
 * demon is active."
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint soulLink = 19028, linked = 25228;
    auto w = RealWorld.make();
    auto warlock = w.character(1, "Gul'dan", classWarlock, 60, [soulLink]);
    auto me = warlock.session.inWorld;
    auto voidwalker = warlockWith(w, warlock, summonVoidwalker);
    w.now += 2.seconds;
    assert(w.castAt(warlock, soulLink, voidwalker.guid) == imported!"dmangos.world.spellcast".SpellCastResult.ok);
    assert(voidwalker.auras.find(linked) !is null && me.player.auras.find(linked) !is null, "both linked");
    assert(isClose(me.player.damageMods.school[5], 1.03f) && isClose(voidwalker.fighter.damageDone[0], 1.03f), "3% more");
    const petHealth = voidwalker.values.get!UNIT_FIELD_HEALTH;
    uint damage = 1000;
    me.absorbIncoming(0, damage);
    assert(damage == 700 && voidwalker.values.get!UNIT_FIELD_HEALTH == petHealth - 300, "30% to the demon");
    // The demon's own link splits nothing: what hits it, it takes.
    voidwalker.values.set!UNIT_FIELD_HEALTH(petHealth);
    imported!"dmangos.world.unit".dealDamage(imported!"dmangos.world.unit".UnitRef.init,
        w.context.map(0).unitOf(voidwalker), 100, imported!"dmangos.world.unit".Blow.spell());
    assert(voidwalker.values.get!UNIT_FIELD_HEALTH == petHealth - 100);
    me.unsummonPet(0);
    pass(w, warlock, 1.seconds);
    assert(me.player.auras.find(linked) is null, "as long as the demon is active");
}

/**
 * Demonic Sacrifice (18788): "sacrifices your summoned demon to grant you an effect that lasts 30 min. The effect is
 * canceled if any Demon is summoned. Imp: Increases your Fire damage by 15%. Voidwalker: Restores 3% of total Health
 * every 4 sec. Succubus: Increases your Shadow damage by 15%. Felhunter: Restores 2% of total Mana every 4 sec."
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint demonicSacrifice = 18788;
    foreach (row; [[summonImp, 18789u], [summonVoidwalker, 18790u], [summonSuccubus, 18791u], [summonFelhunter, 18792u]])
    {
        auto w = RealWorld.make();
        auto warlock = w.character(1, "Gul'dan", classWarlock, 60, [demonicSacrifice]);
        auto me = warlock.session.inWorld;
        auto demon = warlockWith(w, warlock, row[0]);
        w.now += 2.seconds;
        assert(w.castAt(warlock, demonicSacrifice, demon.guid) == imported!"dmangos.world.spellcast".SpellCastResult.ok);
        assert(!demon.alive, "the demon sacrificed");
        auto aura = me.player.auras.find(row[1]);
        assert(aura !is null && aura.maxDuration == 30 * 60 * 1000, format!"its effect %s, 30 minutes"(row[1]));
        if (row[0] == summonImp)
            assert(isClose(me.player.damageMods.school[2], 1.15f), "15% more fire damage");
        else if (row[0] == summonSuccubus)
            assert(isClose(me.player.damageMods.school[5], 1.15f), "15% more shadow damage");
        else if (row[0] == summonVoidwalker)
        {
            const most = me.player.values.get!UNIT_FIELD_MAXHEALTH;
            me.player.values.set!UNIT_FIELD_HEALTH(most / 2);
            warlock.read();
            pass(w, warlock, 4.seconds);
            assert(periodicLogs(warlock, me.player.guid, row[1]) == [most * 3 / 100], "3% of its health in 4 seconds");
        }
        warlockWith(w, warlock, summonImp);
        assert(me.player.auras.find(row[1]) is null, "canceled as a demon is summoned");
    }
}

// ---------------------------------------------------------------------------
// Hunter
// ---------------------------------------------------------------------------

/**
 * The hunter's talents on its pet's stats: Endurance Training (19583 .. 19587: "Increases the Health of your pets by
 * 15%", 3% a rank), Thick Hide (19609, 19610, 19612: "Increases the Armor rating of your pets by 30%", 10% a rank),
 * Unleashed Fury (19616 .. 19620: "Increases the damage done by your pets by 20%", 4% a rank), Ferocity (19598 ..
 * 19602: "Increases the critical strike chance of your pets by 15%", 3% a rank), Bestial Swiftness (19596: "Increases
 * the outdoor movement speed of your pets by 30%").
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto hunter = w.character(1, "Rexxar", classHunter, 60, [], raceDwarf);
    auto beast = tamed(w, hunter);
    // (a boar's own: 4% more health, 9% more armor, 10% less damage)
    const health = beast.petData.base.health, armor = beast.petData.base.armor;
    const crit = beast.fighter.crit, run = beast.speeds[MoveType.run];
    foreach (rank, id; [19583u, 19584, 19585, 19586, 19587])
    {
        talent(w, hunter, id);
        assert(beast.values.get!UNIT_FIELD_MAXHEALTH == scaled(health, 1.04 * (1 + 0.03 * (rank + 1))),
            format!"Endurance Training %s"(rank + 1));
        drop(w, hunter, id);
    }
    foreach (rank, id; [19609u, 19610, 19612])
    {
        talent(w, hunter, id);
        assert(beast.values.get!UNIT_FIELD_RESISTANCES(0) == scaled(armor, 1.09 * (1 + 0.1 * (rank + 1))),
            format!"Thick Hide %s: %s of %s"(rank + 1, beast.values.get!UNIT_FIELD_RESISTANCES(0), armor));
        drop(w, hunter, id);
    }
    foreach (rank, id; [19616u, 19617, 19618, 19619, 19620])
    {
        talent(w, hunter, id);
        assert(isClose(beast.fighter.damageDone[0], 0.9f * (1 + 0.04f * (rank + 1))),
            format!"Unleashed Fury %s: %s"(rank + 1, beast.fighter.damageDone[0]));
        drop(w, hunter, id);
    }
    foreach (rank, id; [19598u, 19599, 19600, 19601, 19602])
    {
        talent(w, hunter, id);
        assert(isClose(beast.fighter.crit, crit + 3 * (rank + 1)), format!"Ferocity %s"(rank + 1));
        drop(w, hunter, id);
    }
    talent(w, hunter, 19596);
    assert(isClose(beast.speeds[MoveType.run], run * 1.3f), format!"Bestial Swiftness: %s of %s"(
        beast.speeds[MoveType.run], run));
    drop(w, hunter, 19596);
    assert(isClose(beast.speeds[MoveType.run], run));
}

/// Frenzy (19621 .. 19625): "Gives your pet a 100% chance to gain a 30% attack speed increase for 8 sec after dealing
/// a critical strike" (20% a rank): Frenzy Effect (19615) after the pet's crits, never without the talent.
unittest
{
    if (!haveRealData())
        return;
    enum uint frenzyEffect = 19615;
    foreach (with_; 0 .. 2)
    {
        auto w = RealWorld.make();
        auto hunter = w.character(1, "Rexxar", classHunter, 60, [], raceDwarf);
        if (with_)
            talent(w, hunter, 19625);
        auto beast = tamed(w, hunter);
        auto kobold = foe(w, hunter);
        beast.ai.petAttack(w.context.map(0).unitOf(kobold), w.context.map(0));
        uint crits, swings;
        bool frenzied;
        foreach (_; 0 .. 1200) // two minutes
        {
            pass(w, hunter, 100.msecs);
            foreach (p; hunter.read())
                if (p.opcode == Opcode.SMSG_ATTACKERSTATEUPDATE)
                {
                    auto r = ByteReader(p.body_);
                    const hitInfo = r.read!uint;
                    if (r.readPackedGuid() != beast.guid)
                        continue;
                    ++swings;
                    if (hitInfo & 0x80) // HITINFO_CRITICALHIT
                        ++crits;
                }
            if (auto aura = beast.auras.find(frenzyEffect))
            {
                frenzied = true;
                assert(with_ && crits > 0, "after a crit, with the talent only");
                assert(aura.maxDuration == 8000 && aura.amount[0] == 30);
                break;
            }
        }
        assert(crits > 0, format!"the pet crit: %s of %s"(crits, swings));
        assert(frenzied == (with_ == 1), with_ ? "Frenzy after its crit" : "no Frenzy without the talent");
    }
}

/**
 * Intimidation (19577): "Command your pet to intimidate the target on the next successful melee attack, causing a
 * high amount of threat and stunning the target for 3 sec." The pet's next hit stuns its target (24394) and angers it;
 * its aura is spent.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint intimidation = 19577, intimidated = 24394;
    auto w = RealWorld.make();
    auto hunter = w.character(1, "Rexxar", classHunter, 60, [intimidation], raceDwarf);
    auto beast = tamed(w, hunter);
    auto kobold = foe(w, hunter);
    w.now += 2.seconds;
    assert(w.castAt(hunter, intimidation, beast.guid) == imported!"dmangos.world.spellcast".SpellCastResult.ok);
    assert(beast.auras.find(intimidation) !is null, "on the pet");
    beast.ai.petAttack(w.context.map(0).unitOf(kobold), w.context.map(0));
    foreach (_; 0 .. 100)
    {
        pass(w, hunter, 100.msecs);
        if (kobold.auras.find(intimidated) !is null)
            break;
    }
    auto stun = kobold.auras.find(intimidated);
    assert(stun !is null && stun.maxDuration == 3000, "stunned for 3 seconds");
    assert(beast.auras.find(intimidation) is null, "spent");
    assert(kobold.ai.threatOf(beast.guid) >= 580, "a high amount of threat");
}

/// Spirit Bond (19578, 20895): "While your pet is active, you and your pet will regenerate 2% of total health every
/// 10 sec" (1% at rank 1): its aura (24529, `spell_pet_auras`) on the pet and on the hunter, a tick every 10 seconds.
unittest
{
    if (!haveRealData())
        return;
    enum uint spiritBond = 24529;
    auto w = RealWorld.make();
    auto hunter = w.character(1, "Rexxar", classHunter, 60, [], raceDwarf);
    auto me = hunter.session.inWorld;
    talent(w, hunter, 20895);
    auto beast = tamed(w, hunter);
    pass(w, hunter, 1.seconds);
    assert(beast.auras.find(spiritBond) !is null && me.player.auras.find(spiritBond) !is null, "on both");
    const most = me.player.values.get!UNIT_FIELD_MAXHEALTH, petMost = beast.values.get!UNIT_FIELD_MAXHEALTH;
    me.player.values.set!UNIT_FIELD_HEALTH(most / 2);
    beast.values.set!UNIT_FIELD_HEALTH(petMost / 2);
    hunter.read();
    foreach (_; 0 .. 10)
        pass(w, hunter, 1.seconds);
    const packets = hunter.read();
    uint[] mine, pets;
    foreach (p; packets)
        if (p.opcode == Opcode.SMSG_PERIODICAURALOG)
        {
            auto r = ByteReader(p.body_);
            const target = r.readPackedGuid();
            r.readPackedGuid();
            if (r.read!uint != spiritBond)
                continue;
            r.read!uint;
            r.read!uint;
            (target == me.player.guid ? mine : pets) ~= r.read!uint;
        }
    assert(mine == [most * 2 / 100] && pets == [petMost * 2 / 100], format!"2%% each: %s %s"(mine, pets));
}

/**
 * Improved Mend Pet (19572, 19573): "Gives the Mend Pet spell a 50% chance of cleansing 1 Curse, Disease, Magic or
 * Poison effect from the pet each tick" (15% at rank 1): a poison on the pet is cleansed (24406) within Mend Pet's
 * five ticks, and Mend Pet heals the pet.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint mendPet = 136, poison = 744; // 744: Poison, of a poison's dispel type (4)
    foreach (with_; 0 .. 2)
    {
        auto w = RealWorld.make();
        auto hunter = w.character(1, "Rexxar", classHunter, 60, [mendPet], raceDwarf);
        if (with_)
            talent(w, hunter, 19573);
        auto beast = tamed(w, hunter);
        bool isNew;
        beast.auras.apply(makeAura(spellOf(w, poison), 0x1234, 60, 60_000, false, [1, 0, 0]), beast.values, isNew);
        const most = beast.values.get!UNIT_FIELD_MAXHEALTH;
        beast.values.set!UNIT_FIELD_HEALTH(most / 2);
        w.now += 2.seconds;
        assert(w.castAt(hunter, mendPet, beast.guid) == imported!"dmangos.world.spellcast".SpellCastResult.ok);
        foreach (_; 0 .. 60)
            pass(w, hunter, 100.msecs);
        assert(beast.values.get!UNIT_FIELD_HEALTH > most / 2, "Mend Pet heals");
        assert((beast.auras.find(poison) is null) == (with_ == 1), with_ ? "cleansed" : "not without the talent");
    }
}

/// Improved Scorpid Sting (19491, 19493, 19494): "Reduces the Stamina of targets affected by your Scorpid Sting by 30%
/// of the amount of Strength reduced" (10% a rank): 19486 on the target, by that share.
unittest
{
    if (!haveRealData())
        return;
    enum uint scorpidSting = 3043, staminaReduced = 19486;
    foreach (rank, id; [0u, 19491, 19493, 19494])
    {
        auto w = RealWorld.make();
        auto hunter = w.character(1, "Rexxar", classHunter, 60, [scorpidSting], raceDwarf);
        if (id)
            talent(w, hunter, id);
        equip(hunter, 2504); // a Worn Shortbow, and Rough Arrows: a sting is shot
        {
            import dmangos.world.packets : ClientSetAmmo;

            enum uint roughArrow = 2512;
            hunter.session.inWorld.storeLoot(roughArrow, 200, 0, false);
            hunter.write(Opcode.CMSG_SET_AMMO, ClientSetAmmo(roughArrow));
            hunter.read();
        }
        auto kobold = foe(w, hunter);
        kobold.movement.position.x += 12; // beyond the bow's least range
        imported!"dmangos.world.spellcast".SpellCastResult[] results;
        foreach (_; 0 .. 20)
        {
            w.now += 2.seconds;
            results ~= w.castAt(hunter, scorpidSting, kobold.guid);
            pass(w, hunter, 1.seconds); // (its flight)
            if (kobold.auras.find(scorpidSting) !is null)
                break;
        }
        auto sting = kobold.auras.find(scorpidSting);
        assert(sting !is null, format!"Scorpid Sting landed: %s"(results));
        auto stamina = kobold.auras.find(staminaReduced);
        if (!id)
        {
            assert(stamina is null);
            continue;
        }
        assert(stamina !is null && stamina.amount[0] == sting.amount[0] * cast(int)(10 * rank) / 100,
            format!"rank %s: %s of %s"(rank, stamina is null ? 0 : stamina.amount[0], sting.amount[0]));
        kobold.loseAura(sting, w.context.map(0));
        assert(kobold.auras.find(staminaReduced) is null, "gone with the sting");
    }
}
