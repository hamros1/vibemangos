"""Exercise spells at named objects and creatures across a boundary in disposable schemas."""

import json
import os
import re
import subprocess
import sys

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for


MORTAR_SPELL, MORTAR = 18655, 176557
DOOR_SPELL, DOOR = 11195, 146084
CHEER_SPELL, RACER = 7036, 4252
REBUILD_SPELL, GOLEM = 13951, 2520
CELL = 533.3333 / 8


def adjacent_boundary(regions, worker):
    # Pick the closest split to Northshire where the coordinator is next to the worker.
    hub = (-8949.95, -132.49)
    candidates = []
    for region, first in regions.items():
        if region in worker:
            continue
        for second in (regions[region] for region in worker if region in regions):
            for axis in (0, 1):
                lo, hi = first[axis]
                other_lo, other_hi = second[axis]
                if hi + 1 == other_lo:
                    edge, direction = other_lo * CELL, 1
                elif other_hi + 1 == lo:
                    edge, direction = lo * CELL, -1
                else:
                    continue
                lo = max(first[1 - axis][0], second[1 - axis][0])
                hi = min(first[1 - axis][1], second[1 - axis][1])
                if lo > hi:
                    continue
                middle = min(max(hub[1 - axis], lo * CELL + 2), (hi + 1) * CELL - 2)
                first_at, second_at = list(hub), list(hub)
                first_at[axis], second_at[axis] = edge - direction, edge + direction
                first_at[1 - axis] = second_at[1 - axis] = middle
                cost = sum((left - right)**2 for left, right in zip(first_at, hub))
                candidates.append((cost, first_at, second_at))
    if not candidates:
        raise RuntimeError("no two neighboring regions on Eastern Kingdoms")
    return min(candidates)[1:]


def run(fixture):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    characters = fixture.fresh_schema("characters", "classiccharacters.sql")
    world_source = fixture.base["world_database"].rsplit(";", 1)[-1]
    world_name = fixture.directory.name.replace("-", "_") + "_world"
    fixture.query(f"CREATE DATABASE `{world_name}`")
    fixture.schemas.append(world_name)
    world = fixture.base["world_database"].rsplit(";", 1)[0] + ";" + world_name
    tables = fixture.query(f"SHOW TABLES FROM `{world_source}`").splitlines()
    spawn_tables = ("gameobject", "creature")
    fixture.query("; ".join(f"CREATE SQL SECURITY INVOKER VIEW `{world_name}`.`{table}` AS "
                            f"SELECT * FROM `{world_source}`.`{table}`" for table in tables if table not in spawn_tables))
    for table in spawn_tables:
        fixture.query(f"CREATE TABLE {table} LIKE `{world_source}`.{table}; "
                      f"INSERT INTO {table} SELECT * FROM `{world_source}`.{table}", world)
    ports = available_ports(5)
    world_ports, peer_ports, auth_port = ports[:2], ports[2:4], ports[4]
    for node in range(1, 3):
        name = f"node{node}"
        config = dict(fixture.base, realm_id=1, port=world_ports[node - 1], bind_address="127.0.0.1",
                      login_database=login, world_database=world, character_database=characters,
                      write_log=name + ".writes", metrics_interval_seconds=1)
        config["cluster"] = {
            "name": "named-object-test", "node_id": node, "listen_address": "127.0.0.1",
            "listen_port": peer_ports[node - 1], "coordinator": f"127.0.0.1:{peer_ports[0]}",
            "balance_min_load_us": 1_000_000_000,
        }
        fixture.start_world(name, config)
    wait_for("the worker to own cluster regions",
             lambda: "this node owns [" in fixture.log("node2") and "lease holds" in fixture.log("node2"), 30)
    worker = set(map(int, re.findall(r"\d+", re.findall(r"this node owns \[([^]]+)\]", fixture.log("node2"))[-1])))
    regions = {}
    for region, x0, x1, y0, y1 in re.findall(
            r"region (\d+): map 0, cells x (-?\d+)\.\.(-?\d+), y (-?\d+)\.\.(-?\d+)", fixture.log("node1")):
        regions[int(region)] = ((int(x0), int(x1)), (int(y0), int(y1)))
    source_at, target_at = adjacent_boundary(regions, worker)
    print(f"caster on node 1 at {source_at}, object on node 2 at {target_at}", flush=True)
    auth_config = fixture.directory / "auth.json"
    auth_config.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                           bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
    auth = [AUTH, "-c", auth_config]
    password = "LOCALMORTARTEST"
    for account in ("MORTARCASTER", "MORTARSPAWN"):
        subprocess.run([*auth, "account", "create", account, password], cwd=fixture.directory, check=True, timeout=10)
    fixture.query("UPDATE account SET gmlevel = 3", login)  # the fixture's two test accounts
    fixture.start("auth", auth)
    wait_for("the login server", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, node, account, *actions):
        env = dict(os.environ, REALM="dmangos", WORLD=f"127.0.0.1:{world_ports[node - 1]}")
        result = subprocess.run([sys.executable, REPO / "tools/testclient.py", str(auth_port), account, password, *actions],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40)
        (fixture.directory / (label + ".log")).write_text(result.stdout)
        if result.returncode != 0:
            raise RuntimeError(f"scripted client {label} failed")
        return result.stdout

    caster, spawner = "Mortarcast", "Mortarspawn"
    for node, account, character, position in (
            (1, "MORTARCASTER", caster, source_at), (2, "MORTARSPAWN", spawner, target_at)):
        if "(success)" not in client("create-" + character, node, account, "enum", f"create:{character}:1:1", "drop"):
            raise RuntimeError(f"could not create {character}")
        fixture.query(f"UPDATE characters SET position_x = {position[0]}, position_y = {position[1]}, "
                      f"position_z = 200 WHERE name = '{character}'", characters)
    for spell in (MORTAR_SPELL, DOOR_SPELL, CHEER_SPELL, REBUILD_SPELL):
        fixture.query(f"INSERT INTO character_spell (guid, spell) SELECT guid, {spell} FROM characters "
                      f"WHERE name = '{caster}'", characters)
    before = {table: int(fixture.query(f"SELECT MAX(guid) FROM {table}", world)) for table in spawn_tables}
    client("spawner", 2, "MORTARSPAWN", f"login:{spawner}", f"cmd:.gobject spawn {MORTAR} 1",
           f"cmd:.gobject spawn {DOOR} 1", f"cmd:.npc spawn {RACER}", f"cmd:.npc spawn {GOLEM}", "drop")
    spawned = {}
    for entry, table, high in ((MORTAR, "gameobject", 0xF110), (DOOR, "gameobject", 0xF110),
                               (RACER, "creature", 0xF130), (GOLEM, "creature", 0xF130)):
        row = fixture.query(f"SELECT guid FROM {table} WHERE guid > {before[table]} AND id={entry}", world)
        if not row:
            raise RuntimeError(f"the worker's GM did not spawn {table} {entry}")
        spawned[entry] = (high << 48) | (entry << 24) | int(row)
    wait_for("the object owner to be empty", lambda: "world: 0 players" in fixture.log("node2").split("entered the world")[-1],
             25)
    output = client("caster", 1, "MORTARCASTER", f"login:{caster}", "cmd:.gm on", "listen:2",
                    f"cast:{MORTAR_SPELL}", "listen:2", f"cast:{DOOR_SPELL}", "listen:2",
                    f"cast:{CHEER_SPELL}", "listen:2", f"cast:{REBUILD_SPELL}", "listen:1",
                    f"cancelchannel:{REBUILD_SPELL}", "listen:1", "drop")
    if f"entered the world as '{caster}'" not in fixture.log("node1"):
        raise RuntimeError("the caster was not simulated on node 1")
    for expected in (f"[game object animation] {spawned[MORTAR]:#018x} slot 0",
                     f"[game object state] {spawned[DOOR]:#018x} state 2",
                     f"[creature aura] {spawned[RACER]:#018x} received {CHEER_SPELL}",
                     f"[channel start] {REBUILD_SPELL} for",
                     f"[creature aura] {spawned[GOLEM]:#018x} received {REBUILD_SPELL}",
                     f"[creature aura] {spawned[GOLEM]:#018x} ended {REBUILD_SPELL}"):
        if output.count(expected) != 1:
            raise RuntimeError(f"expected one '{expected}', got {output.count(expected)}")
    print("PASS: node 1 saw the idle node 2's mortar animate, door open, racer gain an aura, and golem's channel cancel",
          flush=True)


if __name__ == "__main__":
    run_test("named-object", run)
