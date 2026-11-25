#!/usr/bin/env python3
"""A quest changes a spawn gate across workers, before and after a hard crash."""

import argparse
import re
import signal
import struct

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from forwarded_summon_recovery import LANDMARKS, different_workers
from outdoor_script_recovery import ACTOR, QUEST


SCRIPT, FLAG, GROUP, EXPRESSION = 8_911_230, 8_911_231, 8_911_232, 8_911_233
SPAWN, ENTRY = 9_101_729, 1429


def run(fixture, phase):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "creature",
                                               "spawn_group", "spawn_group_spawn", "worldstate_expression")
    def location(entry):
        guid, x, y, z = fixture.query("SELECT guid,position_x,position_y,position_z FROM creature "
                                      f"WHERE id={entry} AND map=0 ORDER BY guid LIMIT 1", world).split()
        return int(guid), (float(x) + 1, float(y), float(z))

    giver, (sx, sy, sz) = location(ACTOR)
    destinations = {SPAWN + i: location(entry)[1] for i, entry in enumerate(LANDMARKS)}
    expression = (b"\x01\x02" + struct.pack("<I", FLAG) + b"\x00\x01\x01" + struct.pack("<i", -1) + b"\x00\x00").hex()
    fixture.query(f"INSERT INTO worldstate_expression (Id,Expression) VALUES ({EXPRESSION},'{expression}'); "
                  "INSERT INTO spawn_group (Id,Name,Type,WorldStateExpression) "
                  f"VALUES ({GROUP},'Test world state',0,{EXPRESSION}); "
                  f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,dataint,dataint2,comments) "
                  f"VALUES ({SCRIPT},1000,0,53,{FLAG},-1,'Show the remote spawn'),"
                  f"({SCRIPT},22000,0,53,{FLAG},0,'Remove the remote spawn')", world)
    for guid, (x, y, z) in destinations.items():
        fixture.query("INSERT INTO creature (guid,id,map,position_x,position_y,position_z,MovementType) "
                      f"VALUES ({guid},{ENTRY},0,{x},{y},{z},0); "
                      f"INSERT INTO spawn_group_spawn (Id,Guid) VALUES ({GROUP},{guid}); ", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    sender, receiver, spawn = different_workers(fixture, (sx, sy, sz), destinations)
    dx, dy, dz = destinations[spawn]
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    fixture.query("INSERT INTO character_queststatus (guid,quest,status,rewarded) "
                  f"VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map=0,position_x={sx},position_y={sy},position_z={sz} WHERE guid={leader}; "
                  f"UPDATE characters SET map=0,position_x={dx},position_y={dy},position_z={dz} WHERE guid<>{leader}",
                  characters)
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_world_state BEFORE INSERT ON dmangos_outdoor_world_state FOR EACH ROW "
                      f"SET @hold_world_state = IF(NEW.id={FLAG} AND NEW.value=-1,SLEEP(60),0)", characters)
    start, finish = (fixture.directory / name for name in ("start", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(start), f"questaccept:{ACTOR}:{QUEST}", wait(finish), "logout")
    observer = client("observer", 1, f"login:{names[1]}", "cmd:.cheat god", wait(finish), "logout")
    for worker, name, x, y in ((sender, names[0], sx, sy), (receiver, names[1], dx, dy)):
        arrival = f"'{name}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
        wait_for(f"{name} to reach {worker}", lambda: arrival in fixture.log(worker), 25)
    wait_for("the player to see the quest giver", lambda: f"[creature] {ACTOR} guid {giver}:" in fixture.log("player"), 12)
    wait_for("the observer to finish logging in", lambda: "cheat god" in fixture.log("observer"), 12)
    appeared = f"[creature] {ENTRY} guid {spawn}:"
    assert appeared not in fixture.log("observer")
    script = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{struct.pack('<BI', 0, SCRIPT).hex()}%'"
    state = f"FROM dmangos_outdoor_world_state WHERE realm=1 AND map=0 AND id={FLAG}"
    start.touch()
    connection = ""
    if phase == "during":
        schema = characters.rsplit(";", 1)[-1]
        connection = wait_for("the write to reach the transaction boundary", lambda: fixture.query(
            "SELECT ID FROM information_schema.PROCESSLIST "
            f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_world_state =%'"), 12)
        assert connection.isdecimal()
        assert fixture.query(f"SELECT `cursor` {script}", characters) == "0"
        assert fixture.query(f"SELECT value {state}", characters) == ""
        assert appeared not in fixture.log("observer")
    else:
        wait_for("the remote worker to activate the gate", lambda: appeared in fixture.log("observer"), 10)
        assert fixture.query(f"SELECT `cursor` {script}", characters) == "1"
        assert fixture.query(f"SELECT value {state}", characters) == "-1"

    offset = len(fixture.log("player"))
    nodes[sender].send_signal(signal.SIGKILL)
    assert nodes[sender].wait(timeout=10) == -signal.SIGKILL
    if connection:
        fixture.query(f"KILL CONNECTION {connection}")
        fixture.query("DROP TRIGGER hold_world_state", characters)
    wait_for("the quest player to recover on the original connection",
             lambda: "[new world] map 0 " in fixture.log("player")[offset:], 40)
    wait_for("exactly one native spawn to become visible", lambda: appeared in fixture.log("observer"), 10)
    short_guid = ((ENTRY << 24) | spawn) & 0xFFFFFFFF
    gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
    wait_for("the recovered close step to remove the spawn", lambda: gone.search(fixture.log("observer")), 32)
    assert fixture.log("observer").count(appeared) == 1
    assert len(gone.findall(fixture.log("observer"))) == 1
    assert fixture.query(f"SELECT value {state}", characters) == "0"
    assert fixture.query(f"SELECT COUNT(*) {script}", characters) == "0"
    finish.touch()
    assert observer.wait(timeout=25) == player.wait(timeout=25) == 0
    print(f"PASS: {phase} crash on {sender}, {receiver} showed one spawn and one removal")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after"))
    args = parser.parse_args()
    run_test(f"outdoor-world-state-{args.phase}", lambda fixture: run(fixture, args.phase))
