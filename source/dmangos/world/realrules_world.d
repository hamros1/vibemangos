/**
 * The rules of docs/FORMULAS.md for creatures, instances and professions, tested on the real data (the client's DBC
 * files, Blizzard's tables beside them, the world database): real recipes, creatures and dungeons, asserting the
 * sourced numbers. Run only where `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`). Skinning's
 * and fishing's, which reach into a character's own state, are in `dmangos.world.character`.
 */
module dmangos.world.realrules_world;

version (unittest):

import core.time : minutes;
import dmangos.world.creature : Creature;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.updatefields;

enum ubyte classWarriorId = 1;

/// Crafting: Linen Bandage (3275) is yellow at 30 and grey at 60 in SkillLineAbility.dbc, its chance falling evenly
/// between them (half at its green 45).
unittest
{
    import dmangos.world.enchanting : craftSkillChance;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    bool found;
    foreach (ability; w.context.client.abilitiesForSpell(3275))
    {
        found = true;
        assert(ability.minValue == 30 && ability.maxValue == 60, "Linen Bandage: yellow 30, grey 60");
        const at = (uint skill) => craftSkillChance(skill, ability.maxValue, ability.minValue);
        assert(at(1) == 1000 && at(29) == 1000, "orange: always");
        assert(at(30) == 1000 && at(45) == 500 && at(54) == 200, "yellow to green: (60 - skill) / 30");
        assert(at(59) == 33 && at(60) == 0, "grey: never");
    }
    assert(found);
}

/// The aggro radius: 45 yards at most, reached 25 levels below the creature; a yard a level; 5 yards at least.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto low = w.character(1, "Peasant", classWarriorId, 1, []);
    enum uint mountainBoar = 1190;
    auto boar = cast(Creature) w.context.map(0).findObject(w.enemy(low, mountainBoar));
    assert(boar.template_.detection == 18);
    auto who = low.session.inWorld.unit;
    boar.values.set!UNIT_FIELD_LEVEL(1u);
    assert(boar.ai.aggroRangeFor(who) == 18, "the same level: its detection range");
    boar.values.set!UNIT_FIELD_LEVEL(11u);
    assert(boar.ai.aggroRangeFor(who) == 28, "ten levels above: ten yards more");
    boar.values.set!UNIT_FIELD_LEVEL(60u);
    assert(boar.ai.aggroRangeFor(who) == 45, "59 levels above: the 45 yard cap");
    auto high = w.character(2, "Hero", classWarriorId, 60, []);
    boar.values.set!UNIT_FIELD_LEVEL(10u);
    assert(boar.ai.aggroRangeFor(high.session.inWorld.unit) == 5, "50 levels below: melee range");
}

/// The leash: a creature chases 11 s up to level 29, 12 s from 30, 13 s from 40, 14 s from 45 and 15 s from 50.
unittest
{
    import dmangos.world.creatureai : pursuitTime;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const boar = 1190 in w.context.data.creatureTemplates;     // Mountain Boar, 10-11
    const ogre = 2287 in w.context.data.creatureTemplates;     // Crushridge Warmonger, 34-35 (Alterac Mountains)
    assert(boar !is null && ogre !is null);
    assert(pursuitTime(boar.minLevel) == 11_000 && pursuitTime(ogre.minLevel) == 12_000);
}

/// Raid resets: MapDifficulty's intervals, as patch 1.9.0 set them: Molten Core 7 days, Zul'Gurub 3, Onyxia 5; a
/// dungeon none.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    bool known;
    if (w.context.client.resetIntervalDays(409, known) == 0 && !known)
        return; // no data/instance-resets.csv: instance_template's (tools/fetch-instance-resets.py)
    assert(w.context.raidResetDays(409) == 7 && w.context.raidResetDays(469) == 7 && w.context.raidResetDays(533) == 7);
    assert(w.context.raidResetDays(309) == 3 && w.context.raidResetDays(509) == 3);
    assert(w.context.raidResetDays(249) == 5);
    assert(w.context.client.resetIntervalDays(36, known) == 0 && known, "the Deadmines: no lockout");
}

/// Five new dungeon copies an hour: the sixth is refused (`TRANSFER_ABORT_TOO_MANY_INSTANCES`), going back into one
/// of the five is not, and an hour on there is room again.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto c = w.character(1, "Delver", classWarriorId, 60, []);
    auto me = c.session.inWorld;
    // The Deadmines, Wailing Caverns, Shadowfang Keep, Ragefire Chasm, Blackfathom Deeps, the Stockade.
    static immutable uint[6] dungeons = [36, 43, 33, 389, 48, 34];
    bool enter(uint mapId)
    {
        const trigger = w.context.data.mapEntranceTrigger(mapId, w.context.client);
        assert(trigger !is null);
        c.read();
        const went = me.teleportTo(mapId, imported!"dmangos.world.movement".Position(trigger.x, trigger.y, trigger.z,
            trigger.orientation));
        bool aborted;
        foreach (p; c.read())
            aborted = aborted || (p.opcode == Opcode.SMSG_TRANSFER_ABORTED && p.body_.length && p.body_[0] == 0x03);
        if (went)
            c.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        c.read();
        assert(went != aborted);
        return went;
    }
    foreach (d; dungeons[0 .. 5])
        assert(enter(d), "five copies");
    assert(!enter(dungeons[5]), "a sixth within the hour");
    assert(enter(dungeons[0]), "back into the first copy");
    w.now += 61.minutes;
    assert(enter(dungeons[5]), "an hour on");
}

/**
 * A creature's own auras: its addon's (`creature_template_addon`), put on it at its first tick, and those that proc as
 * it is struck. Surena Caledon (881) has Frost Armor (12544) from her addon; a player's swing that lands on her
 * chills them (Chill, 6136), as Frost Armor's proc says.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.unit : Blow, dealDamage;

    enum uint surena = 881, frostArmor = 12_544, chill = 6136;
    auto w = RealWorld.make();
    auto hero = w.character(1, "Hero", classWarriorId, 9, []); // her level: far above her, her spells miss
    auto map = w.context.map(0);
    auto her = cast(Creature) map.findObject(w.enemy(hero, surena));
    her.tick(map, 100);
    assert(her.auras.find(frostArmor) !is null, "no Frost Armor from her addon");
    auto player = hero.session.inWorld;
    assert(player.player.auras.find(chill) is null);
    MeleeDamage d;
    d.attacker = player.player.guid;
    d.target = her.guid;
    d.outcome = MeleeHitOutcome.normal;
    d.damage = 20;
    // (Her Chill is a spell at them, which may miss: a few swings.)
    foreach (_; 0 .. 10)
    {
        dealDamage(player.unit, map.unit(her.guid), d.damage, Blow.swing(d));
        hero.read();
        if (player.player.auras.find(chill) !is null)
            break;
    }
    assert(player.player.auras.find(chill) !is null, "her Frost Armor did not chill the one who struck her");
}
