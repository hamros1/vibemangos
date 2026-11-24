#!/usr/bin/env python3
"""Crash a worker around the atomic start of an outdoor child relay."""

import argparse
import signal
import struct

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from outdoor_script_recovery import ACTOR, QUEST


SCRIPT, RELAY = 8_911_201, 8_911_202


def run(fixture, phase):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "dbscripts_on_relay")
    giver, map_id, x, y, z = fixture.query(f"SELECT guid,map,position_x,position_y,position_z FROM creature "
                                          f"WHERE id={ACTOR} ORDER BY guid LIMIT 1", world).split()
    fixture.query(f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,comments) "
                  f"VALUES ({SCRIPT},2000,0,45,{RELAY},'Start delayed relay'), "
                  f"({SCRIPT},2000,1,1,23,'Parent emote'); "
                  "INSERT INTO dbscripts_on_relay (id,delay,priority,command,datalong,comments) "
                  f"VALUES ({RELAY},5000,0,1,24,'Child emote')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    parent_prefix = struct.pack("<BI", 0, SCRIPT).hex()
    relay_prefix = struct.pack("<BI", 3, RELAY).hex()
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_relay BEFORE INSERT ON dmangos_outdoor_script FOR EACH ROW "
                      f"SET @hold_relay = IF(NEW.state LIKE '{relay_prefix}%', SLEEP(60), 0)", characters)
    else:
        fixture.query("CREATE TRIGGER hold_relay BEFORE DELETE ON dmangos_outdoor_script FOR EACH ROW "
                      f"SET @hold_relay = IF(OLD.state LIKE '{parent_prefix}%', SLEEP(60), 0)", characters)

    begin, finish = (fixture.directory / name for name in ("begin", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{QUEST}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    host = wait_for("the player's region worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 25)
    begin.touch()
    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the worker to reach the relay transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_relay =%'"), 16)
    assert connection.isdecimal(), connection
    parent = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{parent_prefix}%'"
    relay = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{relay_prefix}%'"
    assert fixture.query(f"SELECT `cursor` {parent}", characters) == ("0" if phase == "during" else "1")
    assert fixture.query(f"SELECT COUNT(*) {relay}", characters) == ("0" if phase == "during" else "1")
    parent_emote, child_emote = (f"[emote] {giver}: {number}\n" for number in (23, 24))
    assert parent_emote not in log() and child_emote not in log()
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_relay", characters)
    wait_for("the original client to enter the replacement worker", lambda: f"[new world] map {map_id} " in
             log()[offset:], 40)
    wait_for("the parent and its relay to finish on the original connection", lambda:
             parent_emote in log()[offset:] and child_emote in log()[offset:], 18)
    assert log().count(parent_emote) == log().count(child_emote) == 1
    wait_for("both completed scripts to retire their checkpoints", lambda:
             fixture.query(f"SELECT COUNT(*) {parent}", characters) == "0" and
             fixture.query(f"SELECT COUNT(*) {relay}", characters) == "0", 6)
    finish.touch()
    assert player.wait(timeout=25) == 0
    print(f"PASS: {phase} crash on {host}, the parent and one child relay finished on the original connection")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after"))
    args = parser.parse_args()
    run_test(f"scripted-relay-{args.phase}", lambda fixture: run(fixture, args.phase))
