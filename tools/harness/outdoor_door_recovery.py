#!/usr/bin/env python3
"""Crash the worker during or after a delayed outdoor door toggle."""

import argparse
import re
import signal
import struct
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from outdoor_script_recovery import ACTOR, QUEST


DOOR, SPAWN, SCRIPT = 146084, 9_101_690, 8_911_190
GUID = 0xF110 << 48 | DOOR << 24 | SPAWN
RESET = 40


def run(fixture, phase, close):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "gameobject",
                                               "gameobject_template")
    initial, toggled = ("0", "1") if close else ("1", "0")
    if close:
        fixture.query(f"UPDATE gameobject_template SET data0=1 WHERE entry={DOOR}", world)
    giver, map_id, x, y, z = fixture.query(f"SELECT guid,map,position_x,position_y,position_z FROM creature "
                                          f"WHERE id={ACTOR} ORDER BY guid LIMIT 1", world).split()
    fixture.query(f"INSERT INTO gameobject (guid,id,map,position_x,position_y,position_z,rotation3) "
                  f"VALUES ({SPAWN},{DOOR},{map_id},{float(x) + 10},{y},{z},1); "
                  f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,datalong2,comments) "
                  f"VALUES ({SCRIPT},2000,0,{12 if close else 11},{SPAWN},{RESET},'Toggle recovery door'), "
                  f"({SCRIPT},2000,1,1,23,0,'Emote after toggle')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_door BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_door = IF(NEW.actor={GUID}, SLEEP(60), 0)", characters)
    else:
        fixture.query("CREATE TRIGGER hold_door BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      f"SET @hold_door = IF(OLD.kind=2 AND OLD.actor={GUID}, SLEEP(60), 0)", characters)

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
    appearance = re.compile(rf"\[game object\] {DOOR} guid {SPAWN}: .* state ([012])")
    update = f"[game object state] {GUID:#018x} state"
    wait_for("the door's initial state", lambda: appearance.findall(log()) == [initial], 10)
    begin.touch()

    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the worker to reach the requested door transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_door =%'"), 16)
    assert connection.isdecimal(), connection
    queue = "FROM dmangos_outdoor_summon WHERE realm=1 AND kind=2"
    checkpoint = f"FROM dmangos_quest_actor WHERE realm=1 AND actor={GUID}"
    saved = fixture.query(f"SELECT state {checkpoint}", characters)
    emote = f"[emote] {giver}: 23\n"
    assert emote not in log(), "the script advanced while the door request was unconfirmed"
    if phase == "during":
        assert f"{update} {toggled}" not in log()
        assert not saved
        assert fixture.query(f"SELECT actor {queue}", characters) == "0"
    else:
        reset_at, = struct.unpack_from("<q", bytes.fromhex(saved))
        assert fixture.query(f"SELECT actor {queue}", characters) == str(GUID)
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_door", characters)

    def recovered():
        output = log()[offset:]
        entry = f"[new world] map {map_id} "
        return output.split(entry, 1)[1] if entry in output else ""

    wait_for("the door and the later step on the original gateway connection", lambda: recovered() and
             (toggled in appearance.findall(recovered()) or f"{update} {toggled}" in recovered()) and emote in recovered(), 42)
    assert log().count(emote) == 1
    assert fixture.query(f"SELECT COUNT(*) {queue}", characters) == "0"
    if phase == "after":
        assert fixture.query(f"SELECT state {checkpoint}", characters) == saved
        wait_for("the door to reset on its original deadline", lambda: f"{update} {initial}" in recovered(),
                 max(1, reset_at + 4 - time.time()))
        assert abs(time.time() - reset_at) < 4, "the restored door reset outside its original window"
        wait_for("the expired door checkpoint to retire", lambda: fixture.query(
            f"SELECT COUNT(*) {checkpoint}", characters) == "0", 6)
    finish.touch()
    assert player.wait(timeout=25) == 0
    verb = "close" if close else "open"
    print(f"PASS: {phase} crash on {host}, the door's {verb} window and follow-up recovered on the original connection")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after"))
    parser.add_argument("--close", action="store_true", help="close an initially open door")
    args = parser.parse_args()
    direction = "close" if args.close else "open"
    run_test(f"outdoor-door-{direction}-{args.phase}", lambda fixture: run(fixture, args.phase, args.close))
