/**
 * The experience rules (docs/FORMULAS.md, "Experience", "Quest experience") on the real data: creatures and quests as
 * the world database has them, the levels' experience as `player_xp_for_level` has it. Each test names the sourced
 * number and what the rule before gave. They run only with `DMANGOS_REAL_DATA` (`dmangos.world.realspelltests`).
 */
module dmangos.world.realrules_experience;

version (unittest):

import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.player : Player;
import dmangos.world.realspelltests : classWarriorId, haveRealData, RealWorld;
import dmangos.world.testclient;
import dmangos.world.testdata : raceOrc;
import dmangos.world.updatefields;

/// `entry` spawned two yards east of `who`.
private Creature spawnNear(ref RealWorld w, ref TestClient who, uint entry)
{
    auto me = cast(Player) who.session.character;
    auto at = me.position;
    at.x += 2;
    auto creature = w.context.summonCreature(w.context.map(0), entry, at, TempSpawnType.manual, 0, 0);
    assert(creature !is null, "no such creature in the world database");
    who.read();
    return creature;
}

/**
 * Hogger (448), a level 11 elite in Elwynn Forest, to a level 11 alone: (11 * 5 + 45) * 2 = 200 ("Elite XP = 2 *
 * XP", Wowpedia "Mob experience"). The rule before gave elites two and a half everywhere but raids: 250.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto hunter = w.character(101, "Hoggerbane", classWarriorId, 11, []);
    auto me = cast(Player) hunter.session.character;
    const before = me.values[PLAYER_XP];
    auto hogger = spawnNear(w, hunter, 448);
    hunter.session.inWorld.rewardAtKill(hogger);
    assert(me.values[PLAYER_XP] - before == 200, "an open-world elite: double");
}

/**
 * Rest: 5% of a level each 8 hours, at most 150% of a level, shown doubled by the client (kept as the bonus: 2.5% and
 * 75%); a kill doubled while it lasts (Wowpedia "Experience point", "Rest", "Mob experience"; Exhaustion.dbc's 8
 * hours). The rule was already this (CMaNGOS's): the test holds it to the sources.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto orc = w.character(102, "Sleeper", classWarriorId, 11, [], raceOrc);
    auto me = cast(Player) orc.session.character;
    const next = me.values[PLAYER_NEXT_LEVEL_XP];
    assert(next > 0);
    assert(me.computeRest(8 * 3600, 1) == next * 0.05f / 2, "a bubble each 8 hours");
    me.setRestBonus(10 * next, 60);
    assert(me.values[PLAYER_REST_STATE_EXPERIENCE] == cast(uint)(next * 0.75f), "a level and a half, as shown");

    me.setRestBonus(1000, 60);
    const before = me.values[PLAYER_XP];
    auto hogger = spawnNear(w, orc, 448); // a level 11 elite to a level 11: 200
    orc.session.inWorld.rewardAtKill(hogger);
    assert(me.values[PLAYER_XP] - before == 400, "doubled by the rest");
    assert(me.restBonus == 800, "the bonus spent");
}

/**
 * Quest experience: Bounty on Garrick Padfoot (6, level 5) is 340 (its money at the highest level, 204, over 0.6;
 * Wowpedia's 1.x page: 340 XP), 80% at six levels above rounded to fives: 270 (the rule before: 272). Desert Survival
 * Kits (8856) has no level: the player's (the rule before: none).
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.quests : questXp;

    auto w = RealWorld.make();
    const bounty = w.context.data.quests.quest(6);
    assert(bounty !is null && bounty.questLevel == 5);
    assert(questXp(*bounty, 5) == 340 && questXp(*bounty, 10) == 340);
    assert(questXp(*bounty, 11) == 270 && questXp(*bounty, 12) == 205 && questXp(*bounty, 15) == 35);
    const kits = w.context.data.quests.quest(8856);
    assert(kits !is null && kits.questLevel <= 0);
    assert(questXp(*kits, 55) == 650, "of the player's level: 390 / 0.6");
}
