#!/usr/bin/env python3
"""Kill the Defias Traitor's worker after starting the escort."""

import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


TRAITOR, QUEST = 467, 155


def run(fixture):
    world = fixture.world_with_writable_tables("script_waypoint", "waypoint_path_name")
    spawn, map_id, x, y, z = fixture.query(f"SELECT guid,map,position_x,position_y,position_z FROM creature "
                                           f"WHERE id={TRAITOR} ORDER BY guid LIMIT 1", world).split()
    player_x = float(x) + 1
    # Keep the real actor and quest script while shortening the route for a repeatable recovery test.
    fixture.query(f"DELETE FROM waypoint_path_name WHERE PathId={TRAITOR}; "
                  f"DELETE FROM script_waypoint WHERE Entry={TRAITOR} AND PathId=0; "
                  "INSERT INTO script_waypoint (Entry,PathId,Point,PositionX,PositionY,PositionZ,WaitTime) "
                  f"VALUES ({TRAITOR},0,1,{float(x) + 4},{y},{z},9000),"
                  f"({TRAITOR},0,2,{float(x) + 8},{y},{z},1000)", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world)
    if int(previous) > 0:
        fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) "
                      f"VALUES ({leader},{previous},1,1)", characters)
    fixture.query(f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    start, finish = (fixture.directory / flag for flag in ("escort", "finish"))
    escort = client("escort", 0, f"login:{names[0]}", "cmd:.cheat god", wait(start),
                    f"questaccept:{TRAITOR}:{QUEST}", wait(finish), "logout")

    def log():
        output = fixture.log("escort")
        if escort.poll():
            raise RuntimeError(output[-3000:])
        return output

    sight = rf"\[creature\] {TRAITOR} guid {spawn}: "
    wait_for("the original guide to be visible", lambda: re.search(sight, log()), 15)
    host = wait_for("the guide's region worker", lambda: next((tag for tag in ("node1", "node2", "node3")
        if f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})" in
        fixture.log(tag)), ""), 20)
    start.touch()

    def saved():
        return fixture.query(f"SELECT state FROM dmangos_quest_actor WHERE realm=1 AND player={leader}", characters)

    original = wait_for("the active escort checkpoint", saved, 12)
    wait_for("movement from the first checkpoint", lambda: saved() not in ("", original), 10)
    assert fixture.query(f"SELECT status FROM character_queststatus WHERE guid={leader} AND quest={QUEST}",
                         characters) == "3"
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    wait_for("the original client to see the same escort", lambda: f"[new world] map {map_id} " in log()[offset:]
             and re.search(sight, log()[offset:]), 40)
    wait_for("the same escort to finish the original quest",
             lambda: f"[quest objectives done] {QUEST}" in log()[offset:], 35)
    assert len(re.findall(sight, log()[offset:])) == 1
    wait_for("completed quest saved and the escort checkpoint removed", lambda: fixture.query(
        f"SELECT status FROM character_queststatus WHERE guid={leader} AND quest={QUEST}", characters) == "1"
        and not saved(), 12)
    finish.touch()
    if escort.wait(timeout=26):
        raise RuntimeError(fixture.log("escort")[-3000:])
    print(f"PASS: killed {host}, recovered the same Defias Traitor on the existing socket, and completed quest {QUEST}")


if __name__ == "__main__":
    run_test("escort-recovery", run)
