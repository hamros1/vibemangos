#!/usr/bin/env python3
"""Kill the owner of an opened outdoor chest after its first claim."""

import argparse
import math
import re
import signal
import struct

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from group_loot import CHEST, HERBALISM, LOOT_ID, PRIZE, round_positions, world_with_chest
from named_objects import CELL


POTION = 118
POOL, POOLED_SPAWN = 8_910_003, 9_100_001


def run(fixture, pooled):
    world = world_with_chest(fixture, *(("pool_template", "pool_gameobject") if pooled else ()))
    fixture.query(f"UPDATE gameobject_template SET data3=1,data4=0,data5=0 WHERE entry={CHEST}; "
                  f"INSERT INTO gameobject_loot_template (entry,item) VALUES ({LOOT_ID},{POTION})", world)
    if pooled:
        map_id, x, y = 0, -8940, -110
        fixture.query(f"INSERT INTO gameobject (guid,id,map,position_x,position_y,position_z,spawntimesecsmin,"
                      f"spawntimesecsmax) VALUES ({POOLED_SPAWN},{CHEST},0,{x},{y},200,300,300),"
                      f"({POOLED_SPAWN + 1},{CHEST},0,{x + 500},{y},200,300,300); "
                      f"INSERT INTO pool_template (entry,max_limit,description) VALUES ({POOL},1,'Crash recovery'); "
                      f"INSERT INTO pool_gameobject (guid,pool_entry,chance,description) "
                      f"VALUES ({POOLED_SPAWN},{POOL},100,'Chest'),({POOLED_SPAWN + 1},{POOL},0,'Alternate')", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    fixture.query(f"INSERT INTO character_spell (guid,spell) VALUES ({leader},{HERBALISM}); "
                  f"REPLACE INTO character_skills (guid,skill,value,max) VALUES ({leader},182,300,300)", characters)

    def ownership():
        regions = {}
        for node in (1, 2, 3):
            latest = re.findall(r"this node owns \[([^]]*)\]", fixture.log(f"node{node}"))
            if not latest or not latest[-1]:
                return None
            regions[node] = set(map(int, re.findall(r"\d+", latest[-1])))
        return regions

    owners = wait_for("all three workers to own regions", ownership, 30)
    if pooled:
        cell_x, cell_y = math.floor(x / CELL), math.floor(y / CELL)
        region, = [int(region) for region, x0, x1, y0, y1 in re.findall(
            rf"region (\d+): map {map_id}, cells x (-?\d+)\.\.(-?\d+), y (-?\d+)\.\.(-?\d+)", fixture.log("node1"))
            if int(x0) <= cell_x <= int(x1) and int(y0) <= cell_y <= int(y1)]
        owner, = (node for node, regions in owners.items() if region in regions)
    else:
        map_id, (owner, x, y), (_, other_x, other_y), _ = round_positions(fixture.log("node1"), owners)
        # Opening walks to within 1.5 yards, so start well inside the chest's region.
        x, y = x + (x - other_x) * 4, y + (y - other_y) * 4
    fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z=200 "
                  f"WHERE guid={leader}", characters)
    begin, resume, finish = (fixture.directory / flag for flag in ("begin", "resume", "finish"))
    spawn_chest = () if pooled else (f"cmd:.gobject spawn {CHEST} 1",)
    opener = client("opener", 0, f"login:{names[0]}", "cmd:.cheat god", wait(begin), *spawn_chest,
                    f"castgo:{HERBALISM}:{CHEST}:1", wait(resume), f"castgo:{HERBALISM}:{CHEST}", wait(finish), "logout")

    def log():
        output = fixture.log("opener")
        if opener.poll():
            raise RuntimeError(output[-2500:])
        return output

    def rewards():
        rows = fixture.query(f"SELECT itemEntry,SUM(count) FROM item_instance WHERE owner_guid={leader} "
                             f"AND itemEntry IN ({POTION},{PRIZE}) GROUP BY itemEntry", characters)
        return {int(entry): int(count) for entry, count in (row.split() for row in rows.splitlines())}

    tag = f"node{owner}"
    wait_for("the opener on the chest's worker", lambda: f"'{names[0]}' arrived from another node (map {map_id} at "
                                                       f"{x:.1f} {y:.1f})" in fixture.log(tag), 20)
    assert not rewards()
    begin.touch()
    first = wait_for("exactly one item saved after the first claim", lambda: rewards() if len(rewards()) == 1 else None,
                     20)
    spawn, deadline = wait_for("the partly looted chest saved", lambda: fixture.query(
        "SELECT spawn,expires_at FROM dmangos_instance_chest WHERE instance=0", characters), 10).split()
    if pooled:
        assert int(spawn) == POOLED_SPAWN
    original = {int(item): int(count) for item, count in re.findall(r"loot slot \d+: item (\d+) x(\d+)", log())}
    assert original == {POTION: 1, PRIZE: 1}
    offset = len(log())
    nodes[tag].send_signal(signal.SIGKILL)
    assert nodes[tag].wait(timeout=10) == -signal.SIGKILL
    wait_for("the original socket to reload the same chest",
             lambda: f"[new world] map {map_id} " in log()[offset:]
             and f"[game object] {CHEST} guid {spawn}:" in log()[offset:], 42)
    assert fixture.query(f"SELECT expires_at FROM dmangos_instance_chest WHERE instance=0 AND spawn={spawn}",
                         characters) == deadline
    resume.touch()
    wait_for("both original items awarded once", lambda: rewards() == original, 20)
    after = {int(item): int(count) for item, count in re.findall(r"loot slot \d+: item (\d+) x(\d+)", log()[offset:])}
    assert after == {item: count for item, count in original.items() if item not in first}
    def saved_respawn():
        if not pooled:
            return fixture.query(f"SELECT COUNT(*) FROM gameobject_respawn WHERE instance=0 AND guid={spawn}",
                                 characters) == "1"
        row = fixture.query(f"SELECT placements FROM dmangos_gameobject_pool WHERE realm=1 AND pool={POOL}", characters)
        if row:
            selected, due = struct.unpack("<Iq", bytes.fromhex(row))
            return selected == int(spawn) and due > 0
        return False

    wait_for("the exhausted chest retired and its respawn saved", lambda: saved_respawn()
        and fixture.query(f"SELECT COUNT(*) FROM dmangos_instance_chest WHERE instance=0 AND spawn={spawn}",
                          characters) == "0", 12)
    finish.touch()
    if opener.wait(timeout=26):
        raise RuntimeError(log()[-3000:])
    print(f"PASS: killed {tag}, reopened chest {spawn} on the original socket, and awarded both drops once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pooled", action="store_true", help="use a chest from a persistent outdoor pool")
    args = parser.parse_args()
    run_test("outdoor-pooled-chest-recovery" if args.pooled else "outdoor-chest-recovery",
             lambda fixture: run(fixture, args.pooled))
