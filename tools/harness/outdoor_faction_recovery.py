#!/usr/bin/env python3
"""Crash a worker around a delayed outdoor faction change."""

import argparse
import re
import signal
import struct
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from outdoor_script_recovery import ACTOR, QUEST


SCRIPT, FACTION = 8_911_220, 35


def run(fixture, phase):
    idle = phase == "idle"
    if idle:
        fixture.base["grid_cleanup_delay_seconds"] = 1
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start")
    spawn, map_id, x, y, z = fixture.query(f"SELECT guid,map,position_x,position_y,position_z FROM creature "
                                          f"WHERE id={ACTOR} ORDER BY guid LIMIT 1", world).split()
    guid = 0xF130 << 48 | ACTOR << 24 | int(spawn)
    reset = f", ({SCRIPT},34000,0,22,0,'Restore the native faction')" if idle else ""
    fixture.query(f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,comments) "
                  f"VALUES ({SCRIPT},2000,0,22,{FACTION},'Change faction'), "
                  f"({SCRIPT},2000,1,1,23,'Signal the faction change finished'){reset}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    prefix = struct.pack("<BI", 0, SCRIPT).hex()
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_faction BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_faction = IF(NEW.actor={guid}, SLEEP(60), 0)", characters)
    elif phase == "after":
        fixture.query("CREATE TRIGGER hold_faction BEFORE DELETE ON dmangos_outdoor_script FOR EACH ROW "
                      f"SET @hold_faction = IF(OLD.state LIKE '{prefix}%', SLEEP(60), 0)", characters)
    begin, finish = (fixture.directory / name for name in ("begin", "finish"))
    leave, return_to_cell = (fixture.directory / name for name in ("leave", "return"))
    away_x = player_x + 400
    trip = (wait(leave), f"worldport:{map_id}:{away_x}:{y}:{z}", wait(return_to_cell),
            f"worldport:{map_id}:{player_x}:{y}:{z}") if idle else ()
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{QUEST}", *trip,
                    wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    worker = wait_for("the original worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                      if arrival in fixture.log(tag)), ""), 25)
    appearance = re.compile(rf"\[creature\] {ACTOR} guid {spawn}: [^\n]+faction (\d+),")
    original = wait_for("the NPC's initial faction", lambda: appearance.search(log()), 10)[1]
    assert original != str(FACTION)
    change = f"[creature faction] {guid:#018x} faction {FACTION}\n"
    emote = f"[emote] {spawn}: 23\n"
    actor = f"FROM dmangos_quest_actor WHERE realm=1 AND actor={guid}"
    begin.touch()
    if idle:
        wait_for("the scripted faction and the next step", lambda: change in log() and emote in log(), 12)
        leave.touch()
        wait_for("the player to leave the NPC's grid", lambda: any(marker in log() for marker in
                 (f"[teleport] to {away_x:.1f}", f"[new world] map {map_id} at {away_x:.1f}")), 12)
        time.sleep(14)  # The map scans idle cells every ten seconds.
        assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == "1"
        offset = len(log())
        return_to_cell.touch()
        wait_for("the NPC to keep its faction after a grid goes idle", lambda:
                 str(FACTION) in appearance.findall(log()[offset:]), 12)
        wait_for("the NPC to regain its faction", lambda:
                 f"[creature faction] {guid:#018x} faction {original}\n" in log()[offset:], 22)
        wait_for("the reset to retire the unused native checkpoint", lambda:
                 fixture.query(f"SELECT COUNT(*) {actor}", characters) == "0", 6)
        finish.touch()
        assert player.wait(timeout=25) == 0
        print("PASS: the scripted faction survived idle cleanup and the reset retired its checkpoint")
        return

    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the worker to reach the faction transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_faction =%'"), 16)
    assert connection.isdecimal(), connection
    parent = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{prefix}%'"
    expected = "0" if phase == "during" else "1"
    assert fixture.query(f"SELECT `cursor` {parent}", characters) == expected
    assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == expected
    assert emote not in log()
    if phase == "during":
        assert change not in log()

    offset = len(log())
    nodes[worker].send_signal(signal.SIGKILL)
    assert nodes[worker].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_faction", characters)

    def recovered():
        output = log()[offset:]
        entry = f"[new world] map {map_id} "
        return output.split(entry, 1)[1] if entry in output else ""

    wait_for("the original gateway connection to see the new faction and the next step", lambda:
             emote in recovered() and (str(FACTION) in appearance.findall(recovered()) or change in recovered()), 42)
    assert log().count(emote) == 1
    if phase == "after":
        assert appearance.findall(recovered())[0] == str(FACTION)
    assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == "1"
    finish.touch()
    assert player.wait(timeout=25) == 0
    print(f"PASS: {phase} crash on {worker}, the NPC kept its scripted faction and the next step ran once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after", "idle"))
    args = parser.parse_args()
    run_test(f"outdoor-faction-{args.phase}", lambda fixture: run(fixture, args.phase))
