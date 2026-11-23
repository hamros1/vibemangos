#!/usr/bin/env python3
"""Pause the shared host of two realms and accept both original invites on the standby."""

import json
import os
import signal
import subprocess
import sys

from cluster_fixture import AUTH, REPO, WORLD, available_ports, run_test, wait_for


def run(fixture):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    realms = ("First", "Silver Hand")
    databases = [fixture.fresh_schema(f"chars{i}", "classiccharacters.sql") for i in (1, 2)]
    fixture.query("UPDATE realmlist SET name='First',port=0 WHERE id=1; "
                  "INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone) "
                  "VALUES (2,'Silver Hand','127.0.0.1',0,1,2,1)", login)
    ports = available_ports(17)
    host_configs = {1: [], 2: []}
    gateway = 4
    voters = (1, 2, 3)
    for i, database in enumerate(databases):
        world_ports = ports[8*i:8*i+4]
        peer_ports = ports[8*i+4:8*i+8]
        roster = [{"node_id": node, "address": f"127.0.0.1:{peer_ports[node-1]}"} for node in voters]
        for node in (*voters, gateway):
            tag = f"realm{i+1}-node{node}"
            config = dict(fixture.base, realm_id=i+1, login_database=login, character_database=database,
                          port=world_ports[node-1], bind_address="127.0.0.1", write_log=tag+".writes",
                          battlegroup="Emberstorm", battlegroup_node=1, battlegroup_standby_node=2,
                          metrics_interval_seconds=1)
            config["cluster"] = dict(name="battlegroup-ha", node_id=node, listen_address="127.0.0.1",
                                     listen_port=peer_ports[node-1], voters=roster, gateway=node == gateway)
            if node in voters:
                config["cluster"]["vote_file"] = tag + ".vote"
            if node in host_configs:
                path = fixture.directory / (tag + ".json")
                path.write_text(json.dumps(config))
                host_configs[node].append(path)
            else:
                fixture.start_world(tag, config)

    def start_host(label, node):
        paths = host_configs[node]
        return fixture.start(label, [WORLD, "-c", paths[0], "--battlegroup-realm", paths[1]])

    primary = start_host("primary", 1)
    slot_query = "SELECT host_slot FROM d_battlegroup_host WHERE battlegroup='Emberstorm' AND expires_at > UTC_TIMESTAMP(6)"
    wait_for("primary shared lease", lambda: fixture.query(slot_query, login) == "1", 55)
    standby = start_host("standby", 2)
    checkpoint = "SELECT revision,node FROM dmangos_bg_queue_checkpoint WHERE realm=1"
    wait_for("primary queue checkpoint", lambda: fixture.query(checkpoint, databases[0]), 25)
    auth_path = fixture.directory / "auth.json"
    auth_path.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                         bind_address="127.0.0.1", port=ports[-1], realms_state_update_delay=1)))
    accounts = ("EMBERONE", "EMBERTWO")
    password = "TESTBATTLEGROUP"
    for account in accounts:
        subprocess.run([AUTH, "-c", auth_path, "account", "create", account, password],
                       cwd=fixture.directory, check=True, timeout=15, stdout=subprocess.DEVNULL)
    fixture.query("UPDATE account SET gmlevel=3", login)
    fixture.start("auth", [AUTH, "-c", auth_path])
    wait_for("auth listening", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, realm, *actions):
        env = dict(os.environ, REALM=realms[realm], WORLD=f"127.0.0.1:{ports[8*realm+gateway-1]}")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[-1]),
                                     accounts[realm], password, *actions], env=env)

    battlemaster = 14981
    x, y, z = fixture.query(f"SELECT position_x,position_y,position_z FROM creature "
                            f"WHERE id={battlemaster} AND map=0 LIMIT 1", fixture.base["world_database"]).split()
    for i, database in enumerate(databases):
        label = f"create{i}"
        if client(label, i, "enum", "create:Echo:1:1", "drop").wait(timeout=25):
            raise RuntimeError(fixture.log(label))
        fixture.query(f"UPDATE characters SET level=60,map=0,position_x={x},position_y={y},position_z={z} "
                      "WHERE name='Echo'", database)

    join = fixture.directory / "join"
    invited = fixture.directory / "force"
    accept = fixture.directory / "accept"
    scoreboard = fixture.directory / "scoreboard"
    clients = []
    for i in range(2):
        commands = ["login:Echo", f"waitfile:{join}", f"bgjoin:{battlemaster}:489", f"waitfile:{invited}"]
        if i == 0:
            commands += ["cmd:.battleground forcestart"] * 2
        commands += [f"waitfile:{accept}", "bgstatus", "bgport:489:1",
                     f"waitfile:{scoreboard}", "pvplog:names", "listen:2", "bgleave:489", "listen:1", "logout"]
        clients.append(client(f"battle{i}", i, *commands))

    def both(value):
        return all(value in fixture.log(f"battle{i}") for i in range(2))

    wait_for("both clients near the battlemaster", lambda: both(f"[creature] {battlemaster} guid"), 20)
    join.touch()
    wait_for("both queued", lambda: both("copy 0 queued"), 15)
    invited.touch()
    wait_for("both original invites", lambda: both(" invited ["), 12)
    revision, node = map(int, fixture.query(checkpoint, databases[0]).split())
    assert node == 1

    primary.send_signal(signal.SIGSTOP)
    try:
        def recovered():
            if standby.poll() is not None:
                raise RuntimeError("standby exited: " + fixture.log("standby")[-2000:])
            value = fixture.query(checkpoint, databases[0])
            after, host = map(int, value.split())
            return host == 2 and after > revision and fixture.query(slot_query, login) == "2"

        wait_for("standby shared queue and durable checkpoint", recovered, 35)
    finally:
        primary.send_signal(signal.SIGCONT)
    if primary.wait(timeout=15) != 2 or "shared lease lost" not in fixture.log("primary"):
        raise RuntimeError("the paused host did not fence itself after resuming")

    accept.touch()
    wait_for("both original clients entered Warsong Gulch", lambda: both("[new world] map 489 "), 18)
    scoreboard.touch()
    for i, process in enumerate(clients):
        code = process.wait(timeout=25)
        log = fixture.log(f"battle{i}")
        if code or log.count(" invited [") < 2 or "[scoreboard names] ['Echo', 'Echo-" not in log:
            raise RuntimeError(log[-5000:])
    print("PASS: one standby claimed both realms, the paused host fenced itself, and both original clients joined the same match")


if __name__ == "__main__":
    run_test("battlegroup-failover", run)
