#!/usr/bin/env python3
"""Crash a region worker around the durable respawn of an outdoor quest object."""

import argparse
import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from outdoor_script_recovery import ACTOR, QUEST


OBJECT, SPAWN, SCRIPT = 177544, 9_101_691, 8_911_191
GUID = 0xF110 << 48 | OBJECT << 24 | SPAWN
DURATION = 36


def run(fixture, phase):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "gameobject")
    giver, map_id, x, y, z = fixture.query(f"SELECT guid,map,position_x,position_y,position_z FROM creature "
                                          f"WHERE id={ACTOR} ORDER BY guid LIMIT 1", world).split()
    fixture.query(f"INSERT INTO gameobject (guid,id,map,position_x,position_y,position_z,rotation3,"
                  f"spawntimesecsmin,spawntimesecsmax) VALUES ({SPAWN},{OBJECT},{map_id},{float(x) + 10},"
                  f"{y},{z},1,-{DURATION},-{DURATION}); "
                  f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,datalong2,comments) "
                  f"VALUES ({SCRIPT},2000,0,9,{SPAWN},{DURATION},'Temporary native quest object'), "
                  f"({SCRIPT},2000,1,1,23,0,'Emote after respawn')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_spawn BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_spawn = IF(NEW.actor={GUID}, SLEEP(60), 0)", characters)
    else:
        fixture.query("CREATE TRIGGER hold_spawn BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      f"SET @hold_spawn = IF(OLD.kind=3 AND OLD.actor={GUID}, SLEEP(60), 0)", characters)

    begin, finish = (fixture.directory / flag for flag in ("begin", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{QUEST}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    host = wait_for("the player's region worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 25)
    appearance = f"[game object] {OBJECT} guid {SPAWN}:"
    emote = f"[emote] {giver}: 23\n"
    assert appearance not in log()
    begin.touch()
    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the worker to reach the respawn transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_spawn =%'"), 16)
    assert connection.isdecimal(), connection
    expiry = time.monotonic() + DURATION
    queue = "FROM dmangos_outdoor_summon WHERE realm=1 AND kind=3"
    checkpoint = f"FROM dmangos_quest_actor WHERE realm=1 AND actor={GUID}"
    assert emote not in log(), "the script advanced ahead of the respawn receipt"
    if phase == "during":
        assert appearance not in log()
        assert fixture.query(f"SELECT COUNT(*) {checkpoint}", characters) == "0"
        assert fixture.query(f"SELECT actor {queue}", characters) == "0"
    else:
        assert fixture.query(f"SELECT COUNT(*) {checkpoint}", characters) == "1"
        assert fixture.query(f"SELECT actor {queue}", characters) == str(GUID)

    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_spawn", characters)

    def recovered():
        output = log()[offset:]
        entry = f"[new world] map {map_id} "
        return output.split(entry, 1)[1] if entry in output else ""

    wait_for("the original connection to see the restored spawn and follow-up", lambda:
             appearance in recovered() and emote in recovered(), 40)
    assert recovered().count(appearance) == log().count(emote) == 1
    assert fixture.query(f"SELECT COUNT(*) {checkpoint}", characters) == "1"
    assert fixture.query(f"SELECT COUNT(*) {queue}", characters) == "0"
    if phase == "after":
        short_guid = ((OBJECT & 0xFF) << 24) | SPAWN
        gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
        wait_for("the native object to expire on its original deadline", lambda:
                 gone.search(recovered().rsplit(appearance, 1)[1]), max(1, expiry + 4 - time.monotonic()))
        assert abs(time.monotonic() - expiry) < 4
        wait_for("the expired spawn checkpoint to retire", lambda: fixture.query(
            f"SELECT COUNT(*) {checkpoint}", characters) == "0", 6)

    finish.touch()
    assert player.wait(timeout=25) == 0
    print(f"PASS: {phase} crash on {host}, one temporary native spawn and its follow-up recovered")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after"))
    args = parser.parse_args()
    run_test(f"scripted-spawn-{args.phase}", lambda fixture: run(fixture, args.phase))
