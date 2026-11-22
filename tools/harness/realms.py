#!/usr/bin/env python3
"""Run two clusters on one realm list and exercise shared login state."""

import json
import os
import subprocess
import sys

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for


def run(fixture):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    characters = {realm: fixture.fresh_schema(f"chars{realm}", "classiccharacters.sql") for realm in (1, 2)}
    fixture.query("UPDATE realmlist SET port = 0 WHERE id = 1", login)
    fixture.query("INSERT INTO realmlist (id, name, address, port, icon, realmflags, timezone) "
                  "VALUES (2, 'Second realm', '127.0.0.1', 0, 1, 2, 1)", login)

    ports = available_ports(11)
    configs = {}
    for realm, start in ((1, 0), (2, 4)):
        for node in (1, 2):
            name = f"realm{realm}-node{node}"
            config = dict(fixture.base, realm_id=realm, login_database=login, character_database=characters[realm],
                          port=ports[start + node - 1], bind_address="127.0.0.1", write_log=name + ".writes",
                          metrics_interval_seconds=1)
            config["cluster"] = {
                "name": "same-name", "node_id": node, "listen_address": "127.0.0.1",
                "listen_port": ports[start + node + 1], "coordinator": f"127.0.0.1:{ports[start + 2]}",
            }
            configs[realm, node] = config
            fixture.start_world(name, config)

    def realms_published():
        rows = fixture.query("SELECT id, port FROM realmlist WHERE (realmflags & 2) = 0", login).splitlines()
        endpoints = {int(realm): int(port) for realm, port in (row.split() for row in rows)}
        return endpoints.get(1) in ports[:2] and endpoints.get(2) in ports[4:6]

    wait_for("each coordinator to publish a port on its own realm", realms_published, 30)
    for realm in (1, 2):
        wait_for(f"realm {realm}'s worker to join", lambda: "2 member(s)" in fixture.log(f"realm{realm}-node2")
                 and "lease holds" in fixture.log(f"realm{realm}-node2"), 20)

    wrong = dict(configs[2, 2], port=ports[8], write_log="wrong-realm.writes")
    wrong["cluster"] = dict(wrong["cluster"], node_id=3, listen_port=ports[9],
                            coordinator=configs[1, 1]["cluster"]["coordinator"])
    fixture.start_world("wrong-realm", wrong)
    wait_for("a wrong-realm link to be rejected", lambda: "refused: wrongRealm" in fixture.log("wrong-realm"), 20)

    def enter(realm, duration):
        config = configs[realm, 2]
        name = f"clients{realm}"
        clients = fixture.start_clients(name, config, config["port"], "--bots", "1", "--scenario", "idle",
                                        "--duration", duration, "--warmup", "1")
        fixture.wait_for_clients(name, clients)
        return clients

    def active_realm():
        return fixture.query("SELECT active_realm_id FROM account WHERE username = 'LOADBOT1'", login)

    def online(realm):
        return fixture.query("SELECT online FROM characters", characters[realm]) == "1"

    first = enter(1, "25")
    wait_for("the account to become active on realm 1", lambda: active_realm() == "1" and online(1), 10)
    second = enter(2, "35")
    wait_for("both characters to be online", lambda: active_realm() == "2" and online(1) and online(2), 10)
    if fixture.query("SELECT realmid, numchars FROM realmcharacters ORDER BY realmid", login) != "1\t1\n2\t1":
        raise RuntimeError("the shared realm list did not count both characters")

    for realm, clients in ((1, first), (2, second)):
        if clients.wait(timeout=40) or "bots in the world at the end: 1; failed: 0" not in fixture.log(f"clients{realm}"):
            raise RuntimeError(f"the client on realm {realm} did not finish the run")
        wait_for(f"the character on realm {realm} to log out", lambda: not online(realm), 10)
        expected = "2" if realm == 1 else "0"
        wait_for(f"the active realm to be {expected} after logout", lambda: active_realm() == expected, 10)

    # Authenticate and enter both advertised realms using the same account through the real login protocol.
    auth_port = ports[10]
    auth_path = fixture.directory / "auth.json"
    auth_path.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                         bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
    auth = [AUTH, "-c", auth_path]
    account, password = "REALMPROBE", "LOCALREALMTEST"
    subprocess.run([*auth, "account", "create", account, password], cwd=fixture.directory, check=True, timeout=10)
    fixture.start("auth", auth)
    wait_for("authserver to listen", lambda: "listening on" in fixture.log("auth"), 10)
    for realm, realm_name, character in ((1, "dmangos", "Netfirst"), (2, "Second realm", "Netsecond")):
        env = dict(os.environ, REALM=realm_name)
        env.pop("WORLD", None)
        probe = subprocess.run([sys.executable, REPO / "tools/testclient.py", str(auth_port), account, password,
                                f"create:{character}:1:1", f"login:{character}", "drop"],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
        (fixture.directory / f"srp-realm{realm}.log").write_text(probe.stdout)
        if probe.returncode or f"create {character}: 0x2e (success)" not in probe.stdout or "verify world:" not in probe.stdout:
            raise RuntimeError(f"the login client could not enter {realm_name}")
        found = fixture.query(f"SELECT name FROM characters WHERE name = '{character}'", characters[realm])
        if found != character:
            raise RuntimeError(f"{realm_name}'s advertised endpoint did not lead to its character database")

    print("PASS: both realms hosted their own characters through SRP login, and a cross-realm link was rejected", flush=True)


if __name__ == "__main__":
    run_test("realms", run)
