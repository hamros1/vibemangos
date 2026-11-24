#!/usr/bin/env python3
"""Crash an outdoor worker with a partly looted or just depleted scripted chest."""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from group_loot import CHEST as HERB, HERBALISM, LOOT_ID, PRIZE
from outdoor_chest_recovery import POTION
from outdoor_script_recovery import ACTOR, QUEST


CHEST, SPAWN, SCRIPT = 173266, 9_101_700, 8_911_205
GUID = 0xF110 << 48 | CHEST << 24 | SPAWN
DURATION = 70


def run(fixture, phase):
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start", "gameobject",
                                               "gameobject_template", "gameobject_loot_template")
    map_id, x, y, z = fixture.query(f"SELECT map,position_x,position_y,position_z FROM creature "
                                    f"WHERE id={ACTOR} ORDER BY guid LIMIT 1", world).split()
    fixture.query(f"SET @lock = (SELECT data0 FROM gameobject_template WHERE entry={HERB}); "
                  f"UPDATE gameobject_template SET data0=@lock,data1={LOOT_ID} WHERE entry={CHEST}; "
                  f"INSERT INTO gameobject_loot_template (entry,item) VALUES ({LOOT_ID},{POTION}),({LOOT_ID},{PRIZE}); "
                  "INSERT INTO gameobject (guid,id,map,position_x,position_y,position_z,rotation3,"
                  f"spawntimesecsmin,spawntimesecsmax) VALUES ({SPAWN},{CHEST},{map_id},{float(x) + 3},"
                  f"{y},{z},1,-{DURATION},-{DURATION}); "
                  f"UPDATE quest_template SET StartScript={SCRIPT} WHERE entry={QUEST}; "
                  "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,datalong2,comments) "
                  f"VALUES ({SCRIPT},2000,0,9,{SPAWN},{DURATION},'Scripted chest recovery')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}; INSERT INTO character_spell (guid,spell) VALUES ({leader},{HERBALISM}); "
                  f"REPLACE INTO character_skills (guid,skill,value,max) VALUES ({leader},182,300,300)", characters)
    if phase == "empty":
        fixture.query("CREATE TRIGGER hold_chest BEFORE DELETE ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_chest = IF(OLD.actor={GUID}, SLEEP(60), 0)", characters)

    begin, loot, resume, finish = (fixture.directory / name for name in ("begin", "loot", "resume", "finish"))
    open_chest = f"castgo:{HERBALISM}:{CHEST}"
    opens = (open_chest,) if phase == "empty" else (open_chest + ":1", wait(resume), open_chest)
    player = client("player", 0, f"login:{names[0]}", wait(begin), f"questaccept:{ACTOR}:{QUEST}",
                    wait(loot), *opens, wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    def rewards():
        rows = fixture.query(f"SELECT itemEntry,SUM(count) FROM item_instance WHERE owner_guid={leader} "
                             f"AND itemEntry IN ({POTION},{PRIZE}) GROUP BY itemEntry", characters)
        return {int(entry): int(count) for entry, count in (row.split() for row in rows.splitlines())}

    def slots(output):
        return {int(item): int(count) for item, count in re.findall(r"loot slot \d+: item (\d+) x(\d+)", output)}

    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    host = wait_for("the player's region worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 25)
    appearance = f"[game object] {CHEST} guid {SPAWN}:"
    assert appearance not in log()
    assert rewards() == {}
    begin.touch()
    wait_for("the script to spawn its chest", lambda: appearance in log(), 14)
    actor = f"FROM dmangos_quest_actor WHERE realm=1 AND actor={GUID}"
    chest = f"FROM dmangos_instance_chest WHERE instance=0 AND spawn={SPAWN}"
    assert fixture.query(f"SELECT COUNT(*) {actor}", characters) == "1"
    loot.touch()
    expected = {POTION: 1, PRIZE: 1}
    count = len(expected) if phase == "empty" else 1
    awarded = wait_for("the first award or the full chest to commit", lambda:
                       (items if len(items := rewards()) == count else None), 16)
    assert slots(log()) == expected
    expiry = fixture.query(f"SELECT expires_at {chest}", characters)
    assert expiry.isdecimal() and int(expiry) > 0, expiry
    connection = ""
    if phase == "empty":
        schema = characters.rsplit(";", 1)[-1]
        connection = wait_for("the worker to reach the two checkpoint deletions", lambda: fixture.query(
            "SELECT ID FROM information_schema.PROCESSLIST "
            f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_chest =%'"), 15)
        assert connection.isdecimal(), connection

    offset = len(log())
    if phase == "delayed-read":
        fixture.query("RENAME TABLE dmangos_instance_chest TO held_chest_loot; "
                      "CREATE VIEW dmangos_instance_chest AS SELECT instance,spawn,expires_at FROM held_chest_loot",
                      characters)
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    if connection:
        fixture.query(f"KILL CONNECTION {connection}")
        fixture.query("DROP TRIGGER hold_chest", characters)
    wait_for("the original player connection to reload", lambda: f"[new world] map {map_id} " in log()[offset:], 40)
    if phase == "delayed-read":
        wait_for("the replacement to fail its first chest loot read", lambda: any(
            f"could not load loot for outdoor actor {GUID}" in fixture.log(tag) for tag in nodes if tag != host), 10)
        assert appearance not in log()[offset:]
        fixture.query("DROP VIEW dmangos_instance_chest; RENAME TABLE held_chest_loot TO dmangos_instance_chest",
                      characters)
    if phase != "empty":
        wait_for("the same chest GUID to appear after takeover", lambda: appearance in log()[offset:], 8)
        assert fixture.query(f"SELECT expires_at {chest}", characters) == expiry
        resume.touch()
        wait_for("both original items to be awarded once", lambda: rewards() == expected, 16)
        assert slots(log()[offset:]) == {entry: count for entry, count in expected.items() if entry not in awarded}
    wait_for("the depleted chest to retire both checkpoints", lambda:
             fixture.query(f"SELECT COUNT(*) {actor}", characters) == "0" and
             fixture.query(f"SELECT COUNT(*) {chest}", characters) == "0", 13)
    assert rewards() == expected
    finish.touch()
    assert player.wait(timeout=25) == 0
    print(f"PASS: {phase} crash on {host}, the scripted chest awarded each item once and retired both records")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("partial", "empty", "delayed-read"))
    args = parser.parse_args()
    run_test(f"scripted-chest-{args.phase}", lambda fixture: run(fixture, args.phase))
