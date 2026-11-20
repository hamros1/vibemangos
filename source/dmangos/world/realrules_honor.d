/**
 * The honor and reputation rules (docs/FORMULAS.md, "Honor", "Reputation") on the real data: characters, creatures,
 * factions and battlegrounds as the world database and the client's DBC files have them. Each test names the sourced
 * number and what the rule before gave. They run only with `DMANGOS_REAL_DATA` (`dmangos.world.realspelltests`).
 */
module dmangos.world.realrules_honor;

version (unittest):

import dmangos.world.character : Character;
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
 * An honorable kill of a level 60 of no rank by a level 60: 198, rank 1's honor ("CP for Kill (1.8+)", Wowpedia
 * "Honor system (pre-2.0 formulas)"). The rule before (CMaNGOS's level formula) gave 160.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto human = w.character(201, "Victor", classWarriorId, 60, []);
    auto orc = w.character(202, "Victim", classWarriorId, 60, [], raceOrc);
    auto killer = cast(Character) human.session.inWorld, victim = cast(Character) orc.session.inWorld;
    killer.rewardHonorForPlayer(victim, 1);
    assert(killer.player.values.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION == 198);
    killer.rewardHonorForPlayer(victim, 1);
    assert(killer.player.values.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION == 198 + 178, "the second kill today: 90%");
}

/**
 * Battleground bonus honor by bracket, the battlegrounds' templates as the database has them: a unit is 24 in Warsong
 * Gulch's 10-19, 189 in its 50-59, 198 at 60; Alterac Valley's general is 4 units of its 51-60's 198 (Wowpedia "Honor
 * system (pre-2.0 formulas)"). The rule before gave every bracket level 60's curve: 15 a unit.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.battleground : bonusHonor;
    import dmangos.world.bgqueue : BattlegroundType;

    auto w = RealWorld.make();
    const warsong = cast(ubyte) BattlegroundType.warsongGulch in w.context.data.battlegroundTemplates;
    const alterac = cast(ubyte) BattlegroundType.alteracValley in w.context.data.battlegroundTemplates;
    assert(warsong !is null && alterac !is null);
    assert(bonusHonor(1, *warsong, 15) == 24 && bonusHonor(1, *warsong, 55) == 189 && bonusHonor(1, *warsong, 60) == 198);
    assert(bonusHonor(2, *warsong, 25) == 82, "a capture in 20-29");
    assert(bonusHonor(4, *alterac, 52) == 792);
}

/**
 * A grey kill gives a fifth of its reputation (Wowpedia "Reputation": "Grey mobs used to give 20% of the normal
 * reputation until ... Patch 3.0.8"): Captain Keelhaul (2548, level 47, grey to a 60 in 1.12) gives a level 60 5
 * Booty Bay standing of its 25. The rule before tapered: 20.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint bootyBay = 21;
    auto w = RealWorld.make();
    auto orc = w.character(203, "Pirate", classWarriorId, 60, [], raceOrc);
    auto me = cast(Player) orc.session.character;
    const before = me.reputation.standingWith(bootyBay);
    orc.session.inWorld.rewardAtKill(spawnNear(w, orc, 2548));
    assert(me.reputation.standingWith(bootyBay) - before == 5);
}

/**
 * A group's kill gives each member near it all of the reputation, as alone (docs/FORMULAS.md, "Reputation"): two
 * level 47s killing Captain Keelhaul gain 25 Booty Bay standing each. The rule before split it: 12.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGroupName;

    enum uint bootyBay = 21;
    auto w = RealWorld.make();
    auto first = w.character(204, "Gunner", classWarriorId, 47, [], raceOrc);
    auto second = w.character(205, "Mate", classWarriorId, 47, [], raceOrc);
    first.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("mate"));
    second.write(Opcode.CMSG_GROUP_ACCEPT, null);
    assert(w.context.groups.of(204) !is null && w.context.groups.of(204) is w.context.groups.of(205));
    auto a = cast(Player) first.session.character, b = cast(Player) second.session.character;
    const beforeA = a.reputation.standingWith(bootyBay), beforeB = b.reputation.standingWith(bootyBay);
    first.session.inWorld.rewardAtKill(spawnNear(w, first, 2548));
    assert(a.reputation.standingWith(bootyBay) - beforeA == 25);
    assert(b.reputation.standingWith(bootyBay) - beforeB == 25);
}
