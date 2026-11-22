#!/usr/bin/env python3
"""Two realmlist rows, two clusters, colliding character IDs and one Warsong Gulch."""

import json
import os
import subprocess
import sys

from cluster_fixture import AUTH, REPO, WORLD, available_ports, run_test, wait_for


def run(fixture):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    realms = ("First", "Second")
    characters = [fixture.fresh_schema(f"chars{i}", "classiccharacters.sql") for i in (1, 2)]
    fixture.query("UPDATE realmlist SET name='First', port=0 WHERE id=1; "
                  "INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone) "
                  "VALUES (2,'Second','127.0.0.1',0,1,2,1)", login)
    ports = available_ports(9)
    host_configs = []
    for i, database in enumerate(characters):
        world_ports = ports[4*i:4*i+2]
        peer_ports = ports[4*i+2:4*i+4]
        for node in (1, 2):
            tag = f"realm{i+1}-node{node}"
            config = dict(fixture.base, realm_id=i+1, login_database=login, character_database=database,
                          port=world_ports[node-1], bind_address="127.0.0.1", write_log=tag+".writes",
                          battlegroup="Emberstorm", metrics_interval_seconds=1)
            config["cluster"] = dict(name="battlegroup-test", node_id=node, listen_address="127.0.0.1",
                                     listen_port=peer_ports[node-1], coordinator=f"127.0.0.1:{peer_ports[0]}")
            if node == 2:
                fixture.start_world(tag, config)
            else:
                path = fixture.directory / (tag + ".json")
                path.write_text(json.dumps(config))
                host_configs.append(path)

    group = fixture.start("battlegroup", [WORLD, "-c", host_configs[0], "--battlegroup-realm", host_configs[1]])

    def joined():
        if group.poll() is not None:
            raise RuntimeError("battlegroup host exited: " + fixture.log("battlegroup")[-1000:])
        logs = [fixture.log(f"realm{i}-node2") for i in (1, 2)]
        return all("2 member(s)" in log and "lease holds" in log for log in logs)

    wait_for("both independent clusters and their leases", joined, 60)
    auth_path = fixture.directory / "auth.json"
    auth_path.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                         bind_address="127.0.0.1", port=ports[8], realms_state_update_delay=1)))
    accounts = ("EMBERONE", "EMBERTWO")
    password = "TESTBATTLEGROUP"
    for account in accounts:
        subprocess.run([AUTH, "-c", auth_path, "account", "create", account, password],
                       cwd=fixture.directory, check=True, timeout=15)
    fixture.query("UPDATE account SET gmlevel=3", login)
    fixture.start("auth", [AUTH, "-c", auth_path])
    wait_for("the login server", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, i, *actions, node=2):
        env = dict(os.environ, REALM=realms[i], WORLD=f"127.0.0.1:{ports[4*i+node-1]}")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[8]),
                                     accounts[i], password, *actions], env=env)

    entries = (14981, 2804)  # Elfarran in Stormwind, Kurden Bloodclaw in Undercity
    ids = []
    for i, race in enumerate((1, 2)):
        label = f"create{i}"
        creating = client(label, i, "enum", f"create:Echo:{race}:1", "drop", node=1)
        if creating.wait(timeout=25) or "(success)" not in fixture.log(label):
            raise RuntimeError(fixture.log(label))
        ids.append(wait_for(f"Echo on {realms[i]} to be saved", lambda: fixture.query(
            "SELECT guid FROM characters WHERE name='Echo'", characters[i]), 10))
        x, y, z = fixture.query("SELECT position_x,position_y,position_z FROM creature "
                                f"WHERE id={entries[i]} AND map=0 LIMIT 1", fixture.base["world_database"]).split()
        fixture.query(f"UPDATE characters SET level=60,map=0,position_x={x},position_y={y},position_z={z} "
                      "WHERE name='Echo'", characters[i])
    assert ids[0] == ids[1], "the two realms must have colliding local character IDs"

    at_masters = fixture.directory / "masters-ready"
    in_queue = fixture.directory / "both-queued"
    invited = fixture.directory / "both-invited"
    entered = fixture.directory / "both-inside"
    scored = fixture.directory / "both-scored"
    clients = []
    for i, entry in enumerate(entries):
        actions = ["login:Echo", f"waitfile:{at_masters}", f"bgjoin:{entry}:489", f"waitfile:{in_queue}"]
        if i == 0:
            actions.append("say:.battleground forcestart")
        actions += [f"waitfile:{invited}", "bgport:489:1", f"waitfile:{entered}", "pvplog",
                    f"waitfile:{scored}", "bgleave:489", "listen:2", "logout"]
        clients.append(client(f"battle{i}", i, *actions))
    for marker, expected in (
            (at_masters, [f"[creature] {entry} guid" for entry in entries]),
            (in_queue, ["copy 0 queued"] * 2),
            (invited, [" invited ["] * 2),
            (entered, ["[new world] map 489 "] * 2),
            (scored, ["[scoreboard] running, 2 players"] * 2)):
        wait_for(marker.name, lambda: all(value in fixture.log(f"battle{i}") for i, value in enumerate(expected)), 20)
        marker.touch()
    for i, proc in enumerate(clients):
        if proc.wait(timeout=65):
            raise RuntimeError(fixture.log(f"battle{i}")[-1600:])
        log = fixture.log(f"battle{i}")
        if "[scoreboard] running, 2 players" not in log:
            raise RuntimeError(f"{realms[i]} did not see both players in the match")
        if "[new world] map 489 " not in log or "[new world] map 0 " not in log:
            raise RuntimeError(f"{realms[i]} did not enter and return: {log[-2200:]}")
    made = [line for line in fixture.log("battlegroup").splitlines() if "of warsongGulch made" in line]
    assert len(made) == 1, made
    assert all(fixture.query("SELECT map FROM characters WHERE name='Echo'", db) == "0" for db in characters)
    print("PASS: colliding characters from two realm clusters shared one Warsong Gulch and returned home.")


if __name__ == "__main__":
    run_test("battlegroup", run)
