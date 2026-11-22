#!/usr/bin/env python3
"""Run two clusters on one realm list and exercise shared login state."""

from cluster_fixture import available_ports, run_test, wait_for


def run(fixture):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    characters = {realm: fixture.fresh_schema(f"chars{realm}", "classiccharacters.sql") for realm in (1, 2)}
    fixture.query("UPDATE realmlist SET port = 0 WHERE id = 1", login)
    fixture.query("INSERT INTO realmlist (id, name, address, port, icon, realmflags, timezone) "
                  "VALUES (2, 'Second realm', '127.0.0.1', 0, 1, 2, 1)", login)

    ports = available_ports(10)
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

    print("PASS: both realms published and hosted their own characters, and a cross-realm link was rejected", flush=True)


if __name__ == "__main__":
    run_test("realms", run)
