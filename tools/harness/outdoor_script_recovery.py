#!/usr/bin/env python3
"""Kill a worker between the immediate and delayed steps of an outdoor quest script."""

import argparse
import re
import signal
import struct

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


ACTOR, QUEST, SUMMON = 197, 7, 5955
QUEST_START = 0  # DbScriptType.questStart


def run(fixture, clean, after_summon):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start")
    guid, map_id, x, y, z = fixture.query(
        f"SELECT guid,map,position_x,position_y,position_z FROM creature WHERE id={ACTOR} ORDER BY guid LIMIT 1",
        world).split()
    script = 8_910_004
    checkpoint_prefix = struct.pack("<BI", QUEST_START, script).hex()
    checkpoint = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{checkpoint_prefix}%'"
    first, last = f"[emote] {guid}: 66", f"[emote] {guid}: 23"
    summon_delay = 0 if after_summon else 12000
    fixture.query(
        f"UPDATE quest_template SET StartScript={script} WHERE entry={QUEST}; "
        "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,datalong2,dataint,x,y,z,comments) "
        f"VALUES ({script},0,0,1,66,0,0,0,0,0,'Recovery first step'),"
        f"({script},{summon_delay},1,10,{SUMMON},60000,0,{float(x) + 4},{y},{z},'Recovery summon'),"
        f"({script},12000,2,1,23,0,0,0,0,0,'Recovery last step')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1)",
                  characters)
    player_x = float(x) + 1
    fixture.query(f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    if clean and after_summon:
        fixture.query(f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                      f"WHERE guid<>{leader}", characters)
    start, finish = (fixture.directory / flag for flag in ("start", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(start), f"questaccept:{ACTOR}:{QUEST}",
                    wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll():
            raise RuntimeError(output[-3000:])
        return output

    wait_for("the quest giver", lambda: f"[creature] {ACTOR} guid {guid}:" in log(), 20)
    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    host = wait_for("the player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 20)
    start.touch()
    wait_for("the immediate emote", lambda: first in log(), 12)

    def actor_guids(output):
        return set(re.findall(rf"\[creature\] {SUMMON} guid (\d+):", output))

    if after_summon:
        original, = wait_for("the original actor", lambda: actor_guids(log()), 8)
        wait_for("the original actor checkpoint", lambda: fixture.query(
            "SELECT COUNT(*) FROM dmangos_quest_actor WHERE realm=1 AND player=0 "
            f"AND (actor & 16777215)={original}", characters) == "1", 8)
    assert fixture.query(f"SELECT `cursor` {checkpoint}", characters) == ("2" if after_summon else "1")
    assert last not in log()
    offset = len(log())
    nodes[host].send_signal(signal.SIGTERM if clean else signal.SIGKILL)
    assert nodes[host].wait(timeout=25) == (0 if clean else -signal.SIGKILL)
    if not clean:
        wait_for("the existing client to reload through the gateway",
                 lambda: f"[new world] map {map_id} " in log()[offset:], 40)
    wait_for("the delayed summon and emote to resume",
             lambda: last in log()[offset:] and (after_summon and clean or actor_guids(log()[offset:])), 20)
    assert log().count(first) == log().count(last) == 1
    if after_summon:
        assert actor_guids(log()) == {original}
        if clean:
            observing = client("observer", 1, f"login:{names[1]}", wait(finish), "logout")
            wait_for("a new client to see the original actor on its new worker",
                     lambda: actor_guids(fixture.log("observer")) == {original}, 15)
        else:
            assert actor_guids(log()[offset:]) == {original}
    else:
        assert len(actor_guids(log()[offset:])) == 1
    assert fixture.query(f"SELECT COUNT(*) {checkpoint}", characters) == "0"
    assert fixture.query(f"SELECT status FROM character_queststatus WHERE guid={leader} AND quest={QUEST}",
                         characters) == "3"
    finish.touch()
    if player.wait(timeout=25):
        raise RuntimeError(fixture.log("player")[-3000:])
    if clean and after_summon:
        assert observing.wait(timeout=25) == 0
    action = "drained" if clean else "killed"
    print(f"PASS: {action} {host} between steps, preserved one summon and resumed the emote on the original socket")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true", help="drain the worker instead of killing it")
    parser.add_argument("--after-summon", action="store_true", help="crash after the script created its actor")
    args = parser.parse_args()
    label = "outdoor-script-handoff" if args.clean else "outdoor-script-recovery"
    run_test(label, lambda fixture: run(fixture, args.clean, args.after_summon))
