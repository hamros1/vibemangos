#!/usr/bin/env python3
"""Crash the destination worker around a forwarded outdoor despawn."""

import argparse
import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from forwarded_summon_recovery import LANDMARKS, different_workers
from outdoor_script_recovery import ACTOR, QUEST


OBJECT, SPAWN, SCRIPT = 177544, 9_101_695, 8_911_195
COOLDOWN = 34


def run(fixture, phase, standing):
    world = fixture.world_with_writable_tables("quest_template", "creature_questrelation", "dbscripts_on_quest_start",
                                               "gameobject")

    def position(entry):
        guid, *at = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature "
                                  f"WHERE id={entry} AND map=0 ORDER BY guid LIMIT 1", world).split()
        return int(guid), tuple(map(float, at))

    giver, (sx, sy, sz) = position(ACTOR)
    destinations = {}
    for index, landmark in enumerate(LANDMARKS):
        _, (x, y, z) = position(landmark)
        quest, spawn = SCRIPT + index, SPAWN + index
        destinations[quest] = (x + 3, y, z)
        despawn_after = 2000 if standing else 12000
        spawn_step = "" if standing else f"({quest},2000,0,9,{spawn},90,0,0,'Temporary native quest object'), "
        respawn = COOLDOWN if standing else -90
        fixture.query("CREATE TEMPORARY TABLE despawn_quest LIKE quest_template; "
                      f"INSERT INTO despawn_quest SELECT * FROM quest_template WHERE entry={QUEST}; "
                      f"UPDATE despawn_quest SET entry={quest},StartScript={quest},PrevQuestId=0,NextQuestId=0, "
                      "NextQuestInChain=0,ExclusiveGroup=0; INSERT INTO quest_template SELECT * FROM despawn_quest; "
                      f"INSERT INTO creature_questrelation (id,quest) VALUES ({ACTOR},{quest}); "
                      "INSERT INTO dbscripts_on_quest_start "
                      "(id,delay,priority,command,datalong,datalong2,search_radius,data_flags,comments) "
                      f"VALUES {spawn_step}({quest},{despawn_after},0,40,0,0,{spawn},17,'Despawn the object'), "
                      f"({quest},{despawn_after},1,1,23,0,0,0,'Emote after despawn'); "
                      "INSERT INTO gameobject (guid,id,map,position_x,position_y,position_z,rotation3,"
                      f"spawntimesecsmin,spawntimesecsmax) VALUES ({spawn},{OBJECT},0,{x + 3},{y},{z},1,{respawn},{respawn})",
                      world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    sender, receiver, quest = different_workers(fixture, (sx + 1, sy, sz), destinations)
    dx, dy, dz = destinations[quest]
    spawn = SPAWN + quest - SCRIPT
    guid = 0xF110 << 48 | OBJECT << 24 | spawn
    kind = 6 if standing else 4
    fixture.query(f"UPDATE characters SET map=0,position_x={sx + 1},position_y={sy},position_z={sz} "
                  f"WHERE guid={leader}; UPDATE characters SET map=0,position_x={dx + 1},position_y={dy},position_z={dz} "
                  f"WHERE guid<>{leader}", characters)
    if phase == "during" and standing:
        fixture.query("CREATE TRIGGER hold_despawn BEFORE INSERT ON gameobject_respawn FOR EACH ROW "
                      f"SET @hold_despawn = IF(NEW.guid={spawn}, SLEEP(60), 0)", characters)
    elif phase == "during":
        fixture.query("CREATE TRIGGER hold_despawn BEFORE DELETE ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_despawn = IF(OLD.actor={guid} AND EXISTS(SELECT 1 FROM dmangos_outdoor_summon "
                      "WHERE realm=OLD.realm AND kind=4 AND actor=OLD.actor), SLEEP(60), 0)", characters)
    else:
        fixture.query("CREATE TRIGGER hold_despawn BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      f"SET @hold_despawn = IF(OLD.kind={kind} AND OLD.actor={guid}, SLEEP(60), 0)", characters)

    begin, finish = (fixture.directory / name for name in ("begin", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{quest}", wait(finish), "logout")
    observer = client("observer", 1, f"login:{names[1]}", wait(finish), "logout")
    for tag, name, x, y in ((sender, names[0], sx + 1, sy), (receiver, names[1], dx + 1, dy)):
        arrival = f"'{name}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
        wait_for(f"{name} to reach {tag}", lambda: arrival in fixture.log(tag), 25)
    appearance = f"[game object] {OBJECT} guid {spawn}:"
    emote = f"[emote] {giver}: 23\n"
    short_guid = ((OBJECT & 0xFF) << 24) | spawn
    removed = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
    if not standing:
        begin.touch()
    wait_for("the original observer to see the spawned object", lambda: appearance in fixture.log("observer"), 13)
    if standing:
        begin.touch()
    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("the destination worker to reach the despawn transaction boundary", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_despawn =%'"), 18)
    assert connection.isdecimal(), connection
    assert emote not in fixture.log("player"), "the parent script advanced while the despawn was unconfirmed"
    actor = f"FROM dmangos_quest_actor WHERE realm=1 AND actor={guid}"
    receipt = f"FROM dmangos_outdoor_summon WHERE realm=1 AND kind={kind}"
    respawn_row = f"SELECT respawntime FROM gameobject_respawn WHERE instance=0 AND guid={spawn}"
    recorded_actor = fixture.query(f"SELECT actor {receipt}", characters)
    deadline = fixture.query(respawn_row, characters)
    if phase == "during":
        assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == ("0" if standing else "1")
        assert not deadline
        assert recorded_actor == "0", recorded_actor
        assert removed.search(fixture.log("observer")) is None
    else:
        assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == "0"
        assert recorded_actor == str(guid), recorded_actor
        if standing:
            assert deadline.isdecimal() and int(deadline) > time.time()

    offset = len(fixture.log("observer"))
    nodes[receiver].send_signal(signal.SIGKILL)
    assert nodes[receiver].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_despawn", characters)

    def recovered():
        output = fixture.log("observer")[offset:]
        entry = "[new world] map 0 "
        return output.split(entry, 1)[1] if entry in output else ""

    wait_for("the original observer connection to reload", recovered, 40)
    wait_for("the parent to continue after removal on the replacement", lambda: emote in fixture.log("player"), 20)
    assert fixture.log("player").count(emote) == 1
    assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == "0"
    assert fixture.query(f"SELECT COUNT(*) {receipt}", characters) == "0"
    if phase == "after":
        assert appearance not in recovered(), "a committed removal was undone on the replacement"
    elif appearance in recovered():
        wait_for("any recovered pre-commit object to be removed", lambda: removed.search(recovered()), 5)
    if standing:
        recovered_deadline = fixture.query(respawn_row, characters)
        assert recovered_deadline.isdecimal() and int(recovered_deadline) > time.time()
        assert not deadline or recovered_deadline == deadline
        if phase == "after":
            respawn = int(recovered_deadline)
            wait_for("the standing object to return at its original deadline", lambda: appearance in recovered(),
                     max(1, respawn + 4 - time.time()))
            assert abs(time.time() - respawn) < 4
            assert recovered().count(appearance) == 1
    finish.touch()
    assert observer.wait(timeout=25) == player.wait(timeout=25) == 0
    print(f"PASS: {phase} crash on {receiver}, the object stayed removed and its script on {sender} continued once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("during", "after"))
    parser.add_argument("--standing", action="store_true", help="target an ordinary object with a respawn cooldown")
    args = parser.parse_args()
    name = "standing-despawn" if args.standing else "scripted-despawn"
    run_test(f"{name}-{args.phase}", lambda fixture: run(fixture, args.phase, args.standing))
