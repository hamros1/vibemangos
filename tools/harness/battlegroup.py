#!/usr/bin/env python3
"""Two realmlist rows, two clusters, colliding character IDs and one Warsong Gulch."""

import json
import os
import subprocess
import sys

from cluster_fixture import AUTH, REPO, WORLD, available_ports, run_test, wait_for


def run(fixture):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    realms = ("First", "Silver Hand")
    characters = [fixture.fresh_schema(f"chars{i}", "classiccharacters.sql") for i in (1, 2)]
    fixture.query("UPDATE realmlist SET name='First', port=0 WHERE id=1; "
                  "INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone) "
                  "VALUES (2,'Silver Hand','127.0.0.1',0,1,2,1)", login)
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
                                     listen_port=peer_ports[node-1], coordinator=f"127.0.0.1:{peer_ports[0]}",
                                     gateway=node == 2)
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
    fixture.grant_admins(login)
    fixture.start("auth", [AUTH, "-c", auth_path])
    wait_for("the login server", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, i, *actions, node=2):
        env = dict(os.environ, REALM=realms[i], WORLD=f"127.0.0.1:{ports[4*i+node-1]}")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[8]),
                                     accounts[i], password, *actions], env=env)

    battlemaster = 14981  # Elfarran in Stormwind, both characters Alliance
    ids = []
    for i in range(2):
        label = f"create{i}"
        creating = client(label, i, "enum", "create:Echo:1:1", "drop", node=1)
        if creating.wait(timeout=25) or "(success)" not in fixture.log(label):
            raise RuntimeError(fixture.log(label))
        ids.append(wait_for(f"Echo on {realms[i]} to be saved", lambda: fixture.query(
            "SELECT guid FROM characters WHERE name='Echo'", characters[i]), 10))
        x, y, z = fixture.query("SELECT position_x,position_y,position_z FROM creature "
                                f"WHERE id={battlemaster} AND map=0 LIMIT 1", fixture.base["world_database"]).split()
        fixture.query(f"UPDATE characters SET level=60,map=0,position_x={x},position_y={y},position_z={z} "
                      "WHERE name='Echo'", characters[i])
    assert ids[0] == ids[1], "the two realms must have colliding local character IDs"

    at_masters = fixture.directory / "masters-ready"
    in_queue = fixture.directory / "both-queued"
    invited = fixture.directory / "both-invited"
    entered = fixture.directory / "both-inside"
    scored = fixture.directory / "both-scored"
    rejoined = fixture.directory / "raid-restored"
    clients = []
    for i in range(2):
        actions = ["login:Echo", f"waitfile:{at_masters}", f"bgjoin:{battlemaster}:489", f"waitfile:{in_queue}"]
        if i == 0:
            actions += ["cmd:.battleground forcestart"] * 2
        mate = ((2 - i) << 32) | int(ids[1 - i])
        foreign_realm = realms[1 - i].replace(" ", "")
        actions += [f"waitfile:{invited}", "bgport:489:1", f"waitfile:{entered}", "pvplog:names",
                    f"partystats:{mate}", f"whisper:Echo-{foreign_realm}:Whisper from {realms[i]}",
                    "emote:cheers for the team.", f"textemote:101:{mate}",
                    f"waitfile:{scored}"]
        if i == 1:
            actions += ["logout", "login:Echo", "listen:2", f"partystats:{mate}"]
        actions += [f"waitfile:{rejoined}", "bgleave:489", "listen:2", "logout"]
        clients.append(client(f"battle{i}", i, *actions))
    for marker, expected in (
            (at_masters, [f"[creature] {battlemaster} guid"] * 2),
            (in_queue, ["copy 0 queued"] * 2),
            (invited, [" invited ["] * 2),
            (entered, ["[new world] map 489 "] * 2)):
        wait_for(marker.name, lambda: all(value in fixture.log(f"battle{i}") for i, value in enumerate(expected)), 20)
        marker.touch()

    def saw_scores_whispers_and_emotes():
        for i, other in enumerate(reversed(realms)):
            log = fixture.log(f"battle{i}")
            guid = ((2 - i) << 32) | int(ids[1 - i])
            label = "Echo-" + other.replace(" ", "")
            if (f"[scoreboard names] ['Echo', 'Echo-{other}']" not in log
                    or f"[chat type 6] from {guid}: 'Whisper from {other}'" not in log
                    or f"[chat type 7] from {guid}: 'Whisper from {realms[i]}'" not in log
                    or f"[chat type 9] from {guid}: '{label} cheers for the team.'" not in log
                    or f"[chat type 9] from {guid}: '{label} waves at you.'" not in log):
                return False
        return True

    wait_for("both clients' realm-qualified scores, whispers and emotes", saw_scores_whispers_and_emotes, 20)
    scored.touch()
    group_guid = (1 << 32) | int(ids[0])
    online_stats = f"[member stats] {group_guid} mask 0x7ff status 1"

    def restored():
        after_logout = fixture.log("battle1").partition("logout:")[2]
        return (any(line.startswith("  [group list] raid,") and f"Echo ({group_guid}, status 1," in line
                    for line in after_logout.splitlines())
                and online_stats in after_logout)

    wait_for("the reconnected character's raid list and foreign member stats", restored, 20)
    rejoined.touch()
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
    print("PASS: both realms exchanged whispers and emotes, shared scores and party stats, restored a raid member, and returned home.")


if __name__ == "__main__":
    run_test("battlegroup", run)
