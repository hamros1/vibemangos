"""Roll on two cluster nodes with authenticated clients and verify the saved award."""

import argparse
from itertools import permutations
import json
import os
import re
import subprocess
import sys

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for
from named_objects import CELL, adjacent_boundary


CHEST, LOOT_ID, HERBALISM, PRIZE = 1618, 8_910_001, 2366, 1214


def world_with_chest(fixture):
    world = fixture.world_with_writable_tables("gameobject", "gameobject_template", "gameobject_loot_template")
    fixture.query(f"UPDATE gameobject_template SET data1 = {LOOT_ID} WHERE entry = {CHEST}; "
                  f"INSERT INTO gameobject_loot_template (entry, item) VALUES ({LOOT_ID}, {PRIZE})", world)
    return world


def round_positions(log, ownership):
    """Find a shared boundary and, for a third worker, its destination on the same map."""
    for map_id, hub in ((0, (-8949.95, -132.49)), (1, (-618.0, -4252.0))):
        regions = {int(region): ((int(x0), int(x1)), (int(y0), int(y1)))
                   for region, x0, x1, y0, y1 in re.findall(
                       rf"region (\d+): map {map_id}, cells x (-?\d+)\.\.(-?\d+), y (-?\d+)\.\.(-?\d+)", log)}
        for owner, member in permutations(ownership, 2):
            participants = ownership[owner] | ownership[member]
            try:
                owner_at, member_at = adjacent_boundary(
                    {region: rect for region, rect in regions.items() if region in participants}, ownership[member], hub)
            except RuntimeError:
                continue
            destination = ()
            if len(ownership) == 3:
                third = next(iter(ownership.keys() - {owner, member}))
                elsewhere = next((rect for region, rect in regions.items() if region in ownership[third]), None)
                if elsewhere is None:
                    continue
                x, y = ((low + high + 1) * CELL / 2 for low, high in elsewhere)
                destination = third, x, y
            return map_id, (owner, *owner_at), (member, *member_at), destination
    raise RuntimeError("the workers have no shared boundary and destination for this roll")


def run(fixture, migrate):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    characters = fixture.fresh_schema("characters", "classiccharacters.sql")
    world = world_with_chest(fixture)
    count = 3 if migrate else 2
    ports = available_ports(count * 2 + 1)
    world_ports, peer_ports, auth_port = ports[:count], ports[count:-1], ports[-1]

    def owned(label):
        latest = re.findall(r"this node owns \[([^]]*)\]", fixture.log(label))
        return set(map(int, re.findall(r"\d+", latest[-1]))) if latest else set()

    def start_nodes(prefix, total):
        nodes = []
        for index in range(total):
            label = f"{prefix}node{index + 1}"
            config = dict(fixture.base, realm_id=1, port=world_ports[index], bind_address="127.0.0.1",
                          login_database=login, world_database=world, character_database=characters,
                          write_log=label + ".writes", metrics_interval_seconds=1)
            config["cluster"] = {
                "name": "group-loot-test", "node_id": index + 1, "listen_address": "127.0.0.1",
                "listen_port": peer_ports[index], "coordinator": f"127.0.0.1:{peer_ports[0]}",
                "balance_min_load_us": 1_000_000_000,
            }
            nodes.append(fixture.start_world(label, config))
            wait_for(f"{label} to own regions", lambda: owned(label) and "lease holds" in fixture.log(label), 30)
        return nodes

    nodes = start_nodes("", 1)
    auth_config = fixture.directory / "auth.json"
    auth_config.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                           bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
    auth = [AUTH, "-c", auth_config]
    owner, member, password = "Lootprobe", "Lootpartner", "LOCALCHESTTEST"
    for name in (owner, member):
        subprocess.run([*auth, "account", "create", name.upper(), password],
                        cwd=fixture.directory, check=True, timeout=10)
    fixture.query("UPDATE account SET gmlevel = 3", login)
    fixture.start("auth", auth)
    wait_for("the login server", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, name, node, *actions):
        env = dict(os.environ, REALM="dmangos", WORLD=f"127.0.0.1:{world_ports[node - 1]}")
        args = [sys.executable, "-u", REPO / "tools/testclient.py", str(auth_port), name.upper(), password, *actions]
        return fixture.start(label, args, env=env)

    guids = {}
    for name in (owner, member):
        label = "create-" + name
        creating = client(label, name, 1, "enum", f"create:{name}:1:1", "drop")
        if creating.wait(timeout=15) or "(success)" not in fixture.log(label):
            raise RuntimeError(f"creation failed for {name}")
        guid = int(wait_for(f"{name} to be saved",
                            lambda: fixture.query(f"SELECT guid FROM characters WHERE name = '{name}'", characters), 10))
        guids[name] = guid
    for node in reversed(nodes):
        node.terminate()
        if node.wait(timeout=25):
            raise RuntimeError("could not restart the fixture world")
    first, second = guids[owner], guids[member]
    fixture.query(f"INSERT INTO character_spell (guid, spell) VALUES ({first}, {HERBALISM}); "
                  f"REPLACE INTO character_skills (guid, skill, value, max) VALUES ({first}, 182, 300, 300); "
                  f"INSERT INTO groups VALUES (1,{first},0,0,3,{first},2,0,0,0,0,0,0,0,0,0); "
                  f"INSERT INTO group_member VALUES (1,{first},0,0),(1,{second},0,0)", characters)
    start_nodes("round-", count)
    ownership = {node: owned(f"round-node{node}") for node in range(1, count + 1)}
    map_id, owner_at, member_at, destination = round_positions(fixture.log("round-node1"), ownership)
    for guid, (_, x, y) in ((first, owner_at), (second, member_at)):
        fixture.query(f"UPDATE characters SET map = {map_id}, position_x = {x}, position_y = {y}, position_z = 200 "
                      f"WHERE guid = {guid}", characters)
    owner_node, member_node = owner_at[0], member_at[0]
    print(f"opening the chest on node {owner_node} with a party member on node {member_node}, map {map_id}", flush=True)
    movement = ()
    if migrate:
        third, x, y = destination
        gate = fixture.directory / "vote-after-arrival"
        movement = (f"worldport:{map_id}:{x}:{y}:200", f"waitfile:{gate}", "listen:2")
    member_client = client("member", member, member_node, f"login:{member}", "listen:0.5", "rolloffer", *movement,
                           "rollvote:1", "listen:0.5", "drop")
    wait_for("the remote member to log in", lambda: "verify world" in fixture.log("member"), 10)
    owner_client = client("owner", owner, owner_node, f"login:{owner}", f"cmd:.gobject spawn {CHEST} 1", "listen:1",
                          f"castopen:{HERBALISM}:{CHEST}", "rolloffer", "rollvote:2", "listen:0.5", "drop")
    if migrate:
        wait_for(f"the original prompt's member to arrive on node {third}",
                 lambda: f"'{member}' arrived from another node" in fixture.log(f"round-node{third}"), 20)
        gate.touch()
    prompts = set()
    for label, process in (("owner", owner_client), ("member", member_client)):
        if process.wait(timeout=35):
            raise RuntimeError(f"{label} client failed")
        output = fixture.log(label)
        offers = re.findall(r"\[roll offer\] (.*)", output)
        outcomes = re.findall(r"\[roll won\] (.*)", output)
        if len(offers) != 1 or not offers[0].endswith(f"item {PRIZE}") or outcomes != [f"{offers[0]} by player {second}"]:
            raise RuntimeError(f"{label} did not see one prompt and one win by the remote member")
        prompts.add(offers[0])
    if len(prompts) != 1:
        raise RuntimeError("the players received prompts from different loot sources")
    if (f"entered the world as '{owner}'" not in fixture.log(f"round-node{owner_node}") or
            f"entered the world as '{member}'" not in fixture.log(f"round-node{member_node}")):
        raise RuntimeError("the two players did not start on different nodes")
    wait_for("one copy of the prize to be saved to the winner",
             lambda: fixture.query(f"SELECT owner_guid, count FROM item_instance WHERE itemEntry = {PRIZE}",
                                   characters) == f"{second}\t1", 10)
    where = "after a third-node handoff" if migrate else "on two nodes"
    print(f"PASS: both clients saw the same winner {where}, with a single prize in MariaDB", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--migrate-member", action="store_true", help="move the remote member before voting")
    args = parser.parse_args()
    run_test("group-loot", lambda fixture: run(fixture, args.migrate_member))
