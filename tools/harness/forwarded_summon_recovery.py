#!/usr/bin/env python3
"""Crash the sender or destination worker of a durable outdoor summon."""

import argparse
import math
import re
import signal
import struct
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from named_objects import CELL
from outdoor_script_recovery import ACTOR, QUEST, SUMMON


SCRIPT = 8_910_007
LANDMARKS = (1571, 1573, 2226, 2409)  # Existing spawns in different Eastern Kingdoms regions.
DURATION = 36


def configure_world(fixture):
    world = fixture.world_with_writable_tables("quest_template", "creature_questrelation", "dbscripts_on_quest_start",
                                               "dbscripts_on_relay", "creature_spawn_data_template")

    def position(entry):
        guid, *coords = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature "
                                      f"WHERE id={entry} AND map=0 ORDER BY guid LIMIT 1", world).split()
        return int(guid), tuple(map(float, coords))

    giver, source = position(ACTOR)
    relay = SCRIPT + len(LANDMARKS)
    fixture.query(f"INSERT INTO creature_spawn_data_template (Entry,Name,RelayId) VALUES ({relay},'Forwarded relay',{relay}); "
                  f"INSERT INTO dbscripts_on_relay (id,delay,command,datalong,comments) "
                  f"VALUES ({relay},16000,1,24,'Forwarded summon emote after observer recovery')", world)
    destinations = {}
    for index, landmark in enumerate(LANDMARKS):
        _, (x, y, z) = position(landmark)
        quest = SCRIPT + index
        destinations[quest] = (x + 3, y, z)
        fixture.query("CREATE TEMPORARY TABLE summon_quest LIKE quest_template; "
                      f"INSERT INTO summon_quest SELECT * FROM quest_template WHERE entry={QUEST}; "
                      f"UPDATE summon_quest SET entry={quest}, StartScript={quest}, PrevQuestId=0, NextQuestId=0, "
                      "NextQuestInChain=0, ExclusiveGroup=0; INSERT INTO quest_template SELECT * FROM summon_quest; "
                      f"INSERT INTO creature_questrelation (id,quest) VALUES ({ACTOR},{quest}); "
                      "INSERT INTO dbscripts_on_quest_start "
                      "(id,delay,priority,command,datalong,datalong2,dataint4,x,y,z,comments) VALUES "
                      f"({quest},0,0,1,66,0,0,0,0,0,'Start emote'),"
                      f"({quest},1600,1,10,{SUMMON},{DURATION * 1000},{relay},{x + 3},{y},{z},'Forwarded summon'),"
                      f"({quest},1600,2,1,23,0,0,0,0,0,'Emote after delivery')", world)
    return world, giver, source, destinations, relay


def different_workers(fixture, source, destinations):
    bounds = [tuple(map(int, row)) for row in re.findall(
        r"region (\d+): map 0, cells x (-?\d+)\.\.(-?\d+), y (-?\d+)\.\.(-?\d+)", fixture.log("node1"))]

    def region(position):
        x, y = (math.floor(value / CELL) for value in position[:2])
        match, = [rid for rid, x0, x1, y0, y1 in bounds if x0 <= x <= x1 and y0 <= y <= y1]
        return match

    source_region = region(source)
    destination_regions = {quest: region(at) for quest, at in destinations.items()}

    def assigned():
        owners = {}
        for node in ("node1", "node2", "node3"):
            lists = re.findall(r"this node owns \[([^]]*)\]", fixture.log(node))
            if not lists or not lists[-1]:
                return None
            for match in re.findall(r"\d+", lists[-1]):
                owners[int(match)] = node
        sender = owners.get(source_region)
        if sender:
            for quest, destination in destination_regions.items():
                receiver = owners.get(destination)
                if receiver and receiver != sender:
                    return sender, receiver, quest

    return wait_for("a quest giver and summon destination on different workers", assigned, 25)


def run(fixture, phase):
    world, giver, source, destinations, relay = configure_world(fixture)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    sx, sy, sz = source
    sender, receiver, quest = different_workers(fixture, (sx + 1, sy, sz), destinations)
    dx, dy, dz = destinations[quest]
    fixture.query(f"UPDATE characters SET map=0,position_x={sx + 1},position_y={sy},position_z={sz} WHERE guid={leader}; "
                  f"UPDATE characters SET map=0,position_x={dx + 1},position_y={dy},position_z={dz} WHERE guid<>{leader}",
                  characters)
    queue = "FROM dmangos_outdoor_summon WHERE realm=1"
    actors = f"FROM dmangos_quest_actor WHERE realm=1 AND player=0 AND (actor >> 24) & 16777215 = {SUMMON}"
    parent = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{struct.pack('<BI', 0, quest).hex()}%'"
    relay_row = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{struct.pack('<BI', 3, relay).hex()}%'"
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_forward BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_forward = IF((NEW.actor >> 24) & 16777215 = {SUMMON}, SLEEP(60), 0)", characters)
    if phase == "after":
        fixture.query("CREATE TRIGGER hold_forward BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      "SET @hold_forward = IF(OLD.actor <> 0, SLEEP(60), 0)", characters)

    begin, finish = (fixture.directory / flag for flag in ("begin", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{quest}", wait(finish), "logout")
    observer = client("observer", 1, f"login:{names[1]}", "cmd:.cheat god", wait(finish), "logout")

    def log(label, process):
        output = fixture.log(label)
        if process.poll() is not None:
            raise RuntimeError(output[-3500:])
        return output

    def player_log():
        return log("player", player)

    def observer_log():
        return log("observer", observer)

    for tag, name, x, y in ((sender, names[0], sx + 1, sy), (receiver, names[1], dx + 1, dy)):
        wait_for(f"{name} to arrive on {tag}", lambda: f"'{name}' arrived from another node (map 0 at "
                 f"{x:.1f} {y:.1f})" in fixture.log(tag), 25)
    wait_for("the original client to see the quest giver", lambda: f"[creature] {ACTOR} guid {giver}:" in player_log(), 12)
    wait_for("the original observer to finish login", lambda: "cheat god" in observer_log(), 12)

    def drop(tag):
        nodes[tag].send_signal(signal.SIGKILL)
        assert nodes[tag].wait(timeout=10) == -signal.SIGKILL

    parent_emote = f"[emote] {giver}: 23\n"
    saved_actor = None
    if phase == "sender":
        # Wait for the sender's commit while the destination cannot deliver it.
        nodes[receiver].send_signal(signal.SIGSTOP)
        try:
            begin.touch()
            wait_for("the undelivered request to commit", lambda: fixture.query(f"SELECT actor {queue}", characters) == "0", 7)
            assert fixture.query(f"SELECT `cursor` {parent}", characters) == "2"
            assert not fixture.query(f"SELECT actor {actors}", characters)
            assert parent_emote not in player_log()
            recovery_offset = len(player_log())
            observer_offset = len(observer_log())
            drop(sender)
        finally:
            nodes[receiver].send_signal(signal.SIGCONT)
    else:
        begin.touch()
        schema = characters.rsplit(";", 1)[-1]
        connection = wait_for("the destination to reach the expected transaction boundary", lambda: fixture.query(
            "SELECT ID FROM information_schema.PROCESSLIST "
            f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_forward =%'"), 16)
        assert connection.isdecimal(), connection
        assert fixture.query(f"SELECT `cursor` {parent}", characters) == "2"
        if phase == "after":
            actor, saved_at = map(int, fixture.query(f"SELECT actor,saved_at {actors}", characters).split())
            saved_actor = actor & 0xFFFFFF
            assert fixture.query(f"SELECT actor {queue}", characters) == str(actor)
            assert fixture.query(f"SELECT `cursor` {relay_row}", characters) == "0"
        else:
            assert fixture.query(f"SELECT actor {queue}", characters) == "0"
            assert not fixture.query(f"SELECT actor {actors}", characters)
            assert fixture.query(f"SELECT COUNT(*) {relay_row}", characters) == "0"
        assert parent_emote not in player_log(), "the sender advanced past the unconfirmed summon"
        observer_offset = recovery_offset = len(observer_log())
        drop(receiver)
        fixture.query(f"KILL CONNECTION {connection}")
        fixture.query("DROP TRIGGER hold_forward", characters)

    recovering_log = player_log if phase == "sender" else observer_log
    wait_for("the original gateway connection to reload after the crash",
             lambda: "[new world] map 0 " in recovering_log()[recovery_offset:], 40)

    def summon_guids(output):
        return set(map(int, re.findall(rf"\[creature\] {SUMMON} guid (\d+):", output)))

    recovered, = wait_for("the original observer to see one summon", lambda: summon_guids(observer_log()[observer_offset:]), 15)
    if saved_actor is not None:
        assert recovered == saved_actor
    relay_emote = f"[emote] {recovered}: 24\n"
    wait_for("the parent and the summon relay to run", lambda: parent_emote in player_log() and relay_emote in observer_log(), 20)
    assert player_log().count(parent_emote) == observer_log().count(relay_emote) == 1
    assert summon_guids(observer_log()) == {recovered}
    assert fixture.query(f"SELECT actor & 16777215 {actors}", characters) == str(recovered)
    for table in (queue, parent, relay_row):
        assert fixture.query(f"SELECT COUNT(*) {table}", characters) == "0"

    if phase == "after":
        expiry = saved_at + DURATION
        appearance = f"[creature] {SUMMON} guid {recovered}:"
        short_guid = ((SUMMON & 0xFF) << 24) | recovered
        gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
        wait_for("the committed summon to expire on its original deadline", lambda: gone.search(
            observer_log()[observer_offset:].rsplit(appearance, 1)[1]), max(1, expiry + 4 - time.time()))
        assert abs(time.time() - expiry) < 4, "the recovered summon expired outside its original lifetime"
        assert summon_guids(observer_log()) == {recovered}
        wait_for("the expired actor's checkpoint to be retired", lambda: fixture.query(
            f"SELECT COUNT(*) {actors}", characters) == "0", 5)

    finish.touch()
    assert player.wait(timeout=25) == observer.wait(timeout=25) == 0
    print(f"PASS: {phase} crash between {sender} and {receiver}, recovered one summon {recovered} and both scripts")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("sender", "during", "after"))
    args = parser.parse_args()
    run_test(f"forwarded-summon-{args.phase}", lambda fixture: run(fixture, args.phase))
