#!/usr/bin/env python3
"""Crash either worker as a delayed script starts a relay on a neighboring worker."""

import argparse
import signal
import struct

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from forwarded_summon_recovery import different_workers
from outdoor_script_recovery import ACTOR, QUEST


SCRIPT, RELAY, BUDDY, ENTRY = 8_911_210, 8_911_211, 9_101_708, 1429
SX, DX, Y, Z = -5134.3, -5132.3, -1202.0, 200.0


def run(fixture, phase):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "dbscripts_on_relay",
                                               "creature")
    giver = fixture.query(f"SELECT guid FROM creature WHERE id={ACTOR} ORDER BY guid LIMIT 1", world)
    fixture.query(f"UPDATE creature SET map=0, position_x={SX}, position_y={Y}, position_z={Z} WHERE guid={giver}; "
                  "INSERT INTO creature (guid,id,map,position_x,position_y,position_z,MovementType) "
                  f"VALUES ({BUDDY},{ENTRY},0,{DX},{Y},{Z},0); "
                  f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start "
                  "(id,delay,priority,command,datalong,search_radius,data_flags,comments) "
                  f"VALUES ({SCRIPT},2000,0,45,{RELAY},{BUDDY},20,'Start relay on remote buddy'),"
                  f"({SCRIPT},2000,1,1,23,0,0,'Parent emote'); "
                  "INSERT INTO dbscripts_on_relay (id,delay,priority,command,datalong,comments) "
                  f"VALUES ({RELAY},16000,0,1,24,'Child emote after gateway recovery')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    sender, receiver, _ = different_workers(fixture, (SX, Y, Z), {SCRIPT: (DX, Y, Z)})
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map=0,position_x={SX},position_y={Y},position_z={Z} WHERE guid={leader}; "
                  f"UPDATE characters SET map=0,position_x={DX},position_y={Y},position_z={Z} WHERE guid<>{leader}",
                  characters)
    parent_prefix = struct.pack("<BI", 0, SCRIPT).hex()
    relay_prefix = struct.pack("<BI", 3, RELAY).hex()
    if phase == "sender":
        fixture.query("CREATE TRIGGER hold_relay BEFORE INSERT ON dmangos_outdoor_script FOR EACH ROW "
                      f"SET @hold_relay = IF(NEW.state LIKE '{relay_prefix}%', SLEEP(60), 0)", characters)
    else:
        fixture.query("CREATE TRIGGER hold_relay BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      "SET @hold_relay = IF(OLD.kind=5, SLEEP(60), 0)", characters)
    begin, finish = (fixture.directory / name for name in ("begin", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{QUEST}", wait(finish), "logout")
    observer = client("observer", 1, f"login:{names[1]}", wait(finish), "logout")
    for tag, name, x in ((sender, names[0], SX), (receiver, names[1], DX)):
        arrival = f"'{name}' arrived from another node (map 0 at {x:.1f} {Y:.1f})"
        wait_for(f"{name} to reach {tag}", lambda: arrival in fixture.log(tag), 25)
    wait_for("the sender's client to see the remote creature", lambda:
             f"[creature] {ENTRY} guid {BUDDY}:" in fixture.log("player"), 10)
    begin.touch()
    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the selected worker to reach the transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_relay =%'"), 16)
    assert connection.isdecimal(), connection
    parent = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{parent_prefix}%'"
    relay = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{relay_prefix}%'"
    request = "FROM dmangos_outdoor_summon WHERE realm=1 AND kind=5"
    saved = "0" if phase == "sender" else "1"
    assert fixture.query(f"SELECT `cursor` {parent}", characters) == saved
    assert fixture.query(f"SELECT COUNT(*) {relay}", characters) == saved
    assert fixture.query(f"SELECT COUNT(*) {request}", characters) == saved
    parent_emote, child_emote = f"[emote] {giver}: 23\n", f"[emote] {BUDDY}: 24\n"
    assert parent_emote not in fixture.log("player") and child_emote not in fixture.log("observer")
    host, recovering = (sender, "player") if phase == "sender" else (receiver, "observer")
    offset = len(fixture.log(recovering))
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_relay", characters)
    wait_for("the original connection to reload", lambda: "[new world] map 0 " in fixture.log(recovering)[offset:], 40)
    wait_for("the parent and the forwarded relay to finish on the original connections", lambda:
             parent_emote in fixture.log("player") and child_emote in fixture.log("observer"), 20)
    assert fixture.log("player").count(parent_emote) == fixture.log("observer").count(child_emote) == 1
    wait_for("both scripts and the delivery request to retire", lambda:
             all(fixture.query(f"SELECT COUNT(*) {row}", characters) == "0" for row in (parent, relay, request)), 6)
    finish.touch()
    assert observer.wait(timeout=25) == player.wait(timeout=25) == 0
    print(f"PASS: crash on {host}, the parent on {sender} and the relay for {receiver}'s creature finished once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("sender", "receiver"))
    args = parser.parse_args()
    run_test(f"forwarded-relay-{args.phase}", lambda fixture: run(fixture, args.phase))
