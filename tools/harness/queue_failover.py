#!/usr/bin/env python3
"""Check that queue host loss preserves an invite."""

import argparse
import json
import os
import subprocess
import sys

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for


def run(fixture, active_match=False):
    if active_match:
        from battleground_recovery import run as run_match_recovery

        return run_match_recovery(fixture)
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    chars = fixture.fresh_schema("chars", "classiccharacters.sql")
    base = dict(fixture.base, bind_address="127.0.0.1", realm_id=1, metrics_interval_seconds=1, idle_timeout=240,
                login_database=login, character_database=chars)
    realm = fixture.query("SELECT name FROM realmlist WHERE id=1", login)
    ports = available_ports(9)
    voters = [{"node_id": node, "address": f"127.0.0.1:{ports[node + 3]}"} for node in (1, 2, 3)]
    nodes = {}
    for node in (1, 2, 3, 4):
        tag = f"node{node}"
        config = dict(base, port=ports[node - 1], write_log=tag + ".writes")
        config["cluster"] = dict(name="queue-recovery", node_id=node, gateway=node == 4,
                                 listen_address="127.0.0.1", listen_port=ports[node + 3], voters=voters)
        if node != 4:
            config["cluster"]["vote_file"] = tag + ".vote"
        nodes[node] = fixture.start_world(tag, config)

    checkpoint = "SELECT revision,node FROM dmangos_bg_queue_checkpoint WHERE realm=1"
    wait_for("initial queue checkpoint", lambda: fixture.query(checkpoint, chars), 45)
    auth_path = fixture.directory / "auth.json"
    auth_path.write_text(json.dumps(dict(login_database=login, mysql_library=base["mysql_library"],
                                         bind_address="127.0.0.1", port=ports[8], realms_state_update_delay=1)))
    account = "QUEUEKEEPER"
    password = "TESTQUEUEKEEPER"
    subprocess.run([AUTH, "-c", auth_path, "account", "create", account, password],
                   cwd=fixture.directory, check=True, timeout=15, stdout=subprocess.DEVNULL)
    fixture.query("UPDATE account SET gmlevel=3", login)
    fixture.start("auth", [AUTH, "-c", auth_path])
    wait_for("auth listening", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, *actions):
        env = dict(os.environ, REALM=realm, WORLD=f"127.0.0.1:{ports[3]}", DMANGOS_TEST_WAITFILE_SECONDS="40")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[8]),
                                     account, password, *actions], env=env)

    if client("create", "enum", "create:Keeper:1:1", "drop").wait(timeout=25):
        raise RuntimeError(fixture.log("create"))
    battlemaster = 14981
    x, y, z = fixture.query(f"SELECT position_x,position_y,position_z FROM creature "
                            f"WHERE id={battlemaster} AND map=0 LIMIT 1", base["world_database"]).split()
    fixture.query(f"UPDATE characters SET level=60,map=0,position_x={x},position_y={y},position_z={z} "
                  "WHERE name='Keeper'", chars)

    join = fixture.directory / "join"
    accept = fixture.directory / "accept"
    battle = client("battle", "login:Keeper", f"waitfile:{join}", f"bgjoin:{battlemaster}:489",
                    "cmd:.battleground forcestart", "listen:3", f"waitfile:{accept}", "bgstatus", "bgport:489:1",
                    "listen:4", "bgleave:489", "listen:1", "logout")
    wait_for("battlemaster", lambda: f"[creature] {battlemaster} guid" in fixture.log("battle"), 12)
    join.touch()
    wait_for("original invite", lambda: " invited [" in fixture.log("battle"), 10)
    rev, host = map(int, fixture.query(checkpoint, chars).split())
    assert host in (1, 2, 3)
    nodes[host].kill()
    nodes[host].wait(timeout=10)

    def progressed():
        updated, node = map(int, fixture.query(checkpoint, chars).split())
        return node if node != host and updated > rev else None
    successor = wait_for("new queue host checkpoint", progressed, 32)
    accept.touch()
    if battle.wait(timeout=40):
        raise RuntimeError(fixture.log("battle")[-3500:])
    log = fixture.log("battle")
    if log.count(" invited [") < 2 or "[new world] map 489 " not in log:
        raise RuntimeError("the original invitation did not recover\n" + log[-3500:])
    print(f"PASS: queue host {host} failed, host {successor} recovered the open invitation, and the original client entered Warsong Gulch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--active-match", action="store_true", help="kill the Warsong Gulch map host after the battle starts")
    args = parser.parse_args()
    name = "match-takeover" if args.active_match else "queue-takeover"
    run_test(name, lambda fixture: run(fixture, args.active_match))
