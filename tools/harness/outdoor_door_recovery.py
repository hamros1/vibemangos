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
BUTTON = 179558  # The Severed Head of Onyxia
LIFETIME = 52


def run(fixture, phase, close, timed, legacy):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "gameobject",
                                               "gameobject_template")
    initial, toggled = ("0", "1") if close else ("1", "0")
    entry = BUTTON if timed else DOOR
    guid = 0xF110 << 48 | entry << 24 | SPAWN
    delay, reset = (7000, 20) if timed else (2000, 40)
    spawn_step = f"({SCRIPT},1000,0,9,{SPAWN},{LIFETIME},'Spawn the timed button'), " if timed else ""
    respawn = -LIFETIME if timed else 0
    if close:
        fixture.query(f"UPDATE gameobject_template SET data0=1 WHERE entry={entry}", world)
    giver, map_id, x, y, z = fixture.query(f"SELECT guid,map,position_x,position_y,position_z FROM creature "
                                          f"WHERE id={ACTOR} ORDER BY guid LIMIT 1", world).split()
    fixture.query("INSERT INTO gameobject (guid,id,map,position_x,position_y,position_z,rotation3,"
                  f"spawntimesecsmin,spawntimesecsmax) VALUES ({SPAWN},{entry},{map_id},{float(x) + 10},{y},{z},"
                  f"1,{respawn},{respawn}); "
                  f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,datalong2,comments) "
                  f"VALUES {spawn_step}({SCRIPT},{delay},0,{12 if close else 11},{SPAWN},{reset},'Toggle recovery door'), "
                  f"({SCRIPT},{delay},1,1,23,0,'Emote after toggle')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_door BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_door = IF(NEW.actor={guid} AND EXISTS(SELECT 1 FROM dmangos_outdoor_summon "
                      "WHERE realm=NEW.realm AND kind=2 AND actor=NEW.actor), SLEEP(60), 0)", characters)
    else:
        fixture.query("CREATE TRIGGER hold_door BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      f"SET @hold_door = IF(OLD.kind=2 AND OLD.actor={guid}, SLEEP(60), 0)", characters)

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
    appearance = re.compile(rf"\[game object\] {entry} guid {SPAWN}: .* state ([012])")
    update = f"[game object state] {guid:#018x} state"
    if timed:
        assert not appearance.search(log())
        begin.touch()
    wait_for("the door's initial state", lambda: appearance.findall(log()) == [initial], 10)
    expires = time.time() + LIFETIME
    if not timed:
        begin.touch()

    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the worker to reach the requested door transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_door =%'"), 16)
    assert connection.isdecimal(), connection
    queue = "FROM dmangos_outdoor_summon WHERE realm=1 AND kind=2"
    checkpoint = f"FROM dmangos_quest_actor WHERE realm=1 AND actor={guid}"
    saved = fixture.query(f"SELECT state {checkpoint}", characters)
    if legacy:
        saved = saved[:18]
        fixture.query(f"UPDATE dmangos_quest_actor SET state='{saved}' WHERE realm=1 AND actor={guid}", characters)
    emote = f"[emote] {giver}: 23\n"
    assert emote not in log(), "the script advanced while the door request was unconfirmed"
    if phase == "during":
        assert f"{update} {toggled}" not in log()
        assert (len(saved) > 34) if timed else not saved
        assert fixture.query(f"SELECT actor {queue}", characters) == "0"
    else:
        reset_at, = struct.unpack_from("<q", bytes.fromhex(saved))
        assert fixture.query(f"SELECT actor {queue}", characters) == str(guid)
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
        if timed:
            wait_for("the reset button to keep its placement checkpoint", lambda: len(fixture.query(
                f"SELECT state {checkpoint}", characters)) > 34, 6)
        else:
            wait_for("the expired door checkpoint to retire", lambda: fixture.query(
                f"SELECT COUNT(*) {checkpoint}", characters) == "0", 6)
    if timed:
        short_guid = ((entry & 0xFF) << 24) | SPAWN
        gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
        wait_for("the button to expire on its original placement deadline", lambda: gone.search(recovered()),
                 max(1, expires + 4 - time.time()))
        assert abs(time.time() - expires) < 4
        wait_for("the expired button checkpoint to retire", lambda: fixture.query(
            f"SELECT COUNT(*) {checkpoint}", characters) == "0", 6)
    finish.touch()
    assert player.wait(timeout=25) == 0
    verb = "close" if close else "open"
    kind = "button" if timed else "door"
    print(f"PASS: {phase} crash on {host}, the {kind}'s {verb} window and follow-up recovered on the original connection")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after"))
    parser.add_argument("--close", action="store_true", help="close an initially open door")
    parser.add_argument("--timed-button", action="store_true", help="toggle a button with a finite visibility window")
    parser.add_argument("--legacy-toggle", action="store_true", help="recover a standing door stored in the prior format")
    args = parser.parse_args()
    if args.legacy_toggle and (args.timed_button or args.phase != "after"):
        parser.error("--legacy-toggle requires an after-commit crash with a standing door")
    direction = "close" if args.close else "open"
    kind = "button" if args.timed_button else "door"
    run_test(f"outdoor-{kind}-{direction}-{args.phase}", lambda fixture:
             run(fixture, args.phase, args.close, args.timed_button, args.legacy_toggle))
