#!/usr/bin/env python3
"""Kill a Warsong Gulch host and continue the same match on the original gateway connections."""

import argparse
import ast
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys

from cluster_fixture import AUTH, REPO, WORLD, available_ports, run_test, wait_for


def run(fixture, cross_realm=False):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    databases = [fixture.fresh_schema("chars1", "classiccharacters.sql")]
    realms = ["First"]
    fixture.query("UPDATE realmlist SET name='First',port=0 WHERE id=1", login)
    if cross_realm:
        databases.append(fixture.fresh_schema("chars2", "classiccharacters.sql"))
        realms.append("Second")
        fixture.query("INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone) "
                      "VALUES (2,'Second','127.0.0.1',0,1,2,1)", login)

    ports = available_ports(8 * len(realms) + 1)
    host_configs = {1: [], 2: []}
    workers = {}
    for i, database in enumerate(databases):
        roster = [{"node_id": node, "address": f"127.0.0.1:{ports[8*i+3+node]}"} for node in (1, 2, 3)]
        for node in (1, 2, 3, 4):
            tag = f"realm{i+1}-node{node}"
            config = dict(fixture.base, realm_id=i+1, login_database=login, character_database=database, idle_timeout=240,
                          port=ports[8*i+node-1], bind_address="127.0.0.1", write_log=tag+".writes")
            config["cluster"] = dict(name="battle-recovery", node_id=node, listen_address="127.0.0.1",
                                     listen_port=ports[8*i+3+node], voters=roster, gateway=node == 4)
            if node != 4:
                config["cluster"]["vote_file"] = tag+".vote"
            if cross_realm:
                config.update(battlegroup="Emberstorm", battlegroup_node=1, battlegroup_standby_node=2)
            if cross_realm and node in host_configs:
                path = fixture.directory / (tag + ".json")
                path.write_text(json.dumps(config))
                host_configs[node].append(path)
            else:
                process = fixture.start_world(tag, config)
                if i == 0 and node != 4:
                    workers[node] = (tag, process)
    if cross_realm:
        slot_query = "SELECT host_slot FROM d_battlegroup_host WHERE battlegroup='Emberstorm' AND expires_at > UTC_TIMESTAMP(6)"
        for node, tag in [(1, "primary"), (2, "standby")]:
            first, second = host_configs[node]
            workers[node] = (tag, fixture.start(tag, [WORLD, "-c", first, "--battlegroup-realm", second]))
            if node == 1:
                wait_for("primary shared lease", lambda: fixture.query(slot_query, login) == "1", 55)

    queue = "SELECT revision FROM dmangos_bg_queue_checkpoint WHERE realm=1"
    wait_for("initial queue checkpoint", lambda: fixture.query(queue, databases[0]), 55)
    auth_path = fixture.directory / "auth.json"
    auth_path.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                         bind_address="127.0.0.1", port=ports[-1], realms_state_update_delay=1)))
    accounts = ("RECOVERYBLUE", "RECOVERYRED")
    names = ("Keeper", "Watcher")
    password = "TESTRECOVERY"
    for account in accounts:
        subprocess.run([AUTH, "-c", auth_path, "account", "create", account, password],
                       cwd=fixture.directory, check=True, timeout=15, stdout=subprocess.DEVNULL)
    fixture.query("UPDATE account SET gmlevel=3", login)
    fixture.start("auth", [AUTH, "-c", auth_path])
    wait_for("auth listening", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, side, *actions):
        i = side if cross_realm else 0
        env = dict(os.environ, REALM=realms[i], WORLD=f"127.0.0.1:{ports[8*i+3]}",
                   DMANGOS_TEST_WAITFILE_SECONDS="165")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[-1]),
                                     accounts[side], password, *actions], env=env)

    world_db = fixture.base["world_database"]
    masters = (14981, 2804)
    for side, name in enumerate(names):
        race = 1 if side == 0 else 2
        label = f"create{side}"
        if client(label, side, "enum", f"create:{name}:{race}:1", "drop").wait(timeout=25):
            raise RuntimeError(fixture.log(label))
        x, y, z = fixture.query("SELECT position_x,position_y,position_z FROM creature "
                                f"WHERE id={masters[side]} AND map=0 LIMIT 1", world_db).split()
        fixture.query(f"UPDATE characters SET level=60,map=0,position_x={x},position_y={y},position_z={z} "
                      f"WHERE name='{name}'", databases[side if cross_realm else 0])

    x, y, z = fixture.query("SELECT position_x,position_y,position_z FROM gameobject "
                            "WHERE id=179831 AND map=489 LIMIT 1", world_db).split()
    flag_room = f"worldport:489:{float(x)+1}:{y}:{z}"
    triggers = (Path(fixture.base["data_dir"]) / "dbc" / "AreaTrigger.dbc").read_bytes()
    count, fields, size, _ = struct.unpack_from("<4I", triggers, 4)
    assert fields >= 5
    capture_point = next(struct.unpack_from("<3f", triggers, start + 8)
                         for start in range(20, 20 + count * size, size)
                         if struct.unpack_from("<II", triggers, start) == (3646, 489))
    capture = "worldport:489:" + ":".join(map(str, capture_point))
    join, force, accept, play, resume, finish = (fixture.directory / name for name in
                                                 ("join", "force", "accept", "play", "resume", "finish"))
    drop = cross_realm
    battle = []
    for side, name in enumerate(names):
        actions = [f"login:{name}", f"waitfile:{join}", f"bgjoin:{masters[side]}:489", f"waitfile:{force}"]
        if side == 0:
            actions += ["cmd:.battleground forcestart"]
        actions += [f"waitfile:{accept}", "bgport:489:1", f"waitfile:{play}"]
        if side == 0:
            actions += [flag_room, "usego:179831", capture, "trigger:3646", "listen:24",
                        flag_room, "usego:179831"]
            if drop:
                actions += ["cancelaura:23333"]
        actions += [f"waitfile:{resume}"]
        if side == 0 and drop:
            actions += [flag_room, "usego:179786"]
        actions += ["bgstatus", "pvplog:scores"]
        if side == 0:
            actions += [capture, "trigger:3646", "pvplog:scores"]
        actions += [f"waitfile:{finish}", "bgleave:489", "listen:1", "logout"]
        battle.append(client(f"battle{side}", side, *actions))

    def logs():
        return [fixture.log(f"battle{i}") for i in range(2)]

    wait_for("players at their battlemasters",
             lambda: all(f"[creature] {master} guid" in log for master, log in zip(masters, logs())), 20)
    join.touch()
    wait_for("both queued", lambda: all("copy 0 queued" in log for log in logs()), 15)
    force.touch()
    wait_for("both invited", lambda: all(" invited [" in log for log in logs()), 15)
    accept.touch()
    wait_for("both invitations accepted", lambda: all(" in progress [" in log for log in logs()), 18)
    visible_ids = [re.search(r"map 489 copy (\d+) in progress", log)[1] for log in logs()]

    def started():
        for node, (tag, _) in workers.items():
            found = re.search(r"battleground: warsongGulch \(copy (\d+)\) begins", fixture.log(tag))
            if found:
                return node, int(found[1])

    host, instance = wait_for("Warsong Gulch to start", started, 140)
    play.touch()
    score_marker = "[world state] 1581=1"
    flag_marker = "[world state] 1546=4294967295" if drop else "[world state] 1546=1"
    wait_for("first capture", lambda: score_marker in logs()[0], 25)
    wait_for("second objective action", lambda: flag_marker in logs()[0].split(score_marker, 1)[1], 45)
    dropped = []
    if drop:
        dropped = wait_for("the dropped flag's GUID",
                           lambda: re.findall(r"\[game object\] 179786 guid (\d+)", logs()[0]), 3)
    revision_sql = f"SELECT revision FROM dmangos_bg_match_checkpoint WHERE realm=1 AND instance={instance} AND state <> ''"
    revision = int(fixture.query(revision_sql, databases[0]))
    workers[host][1].send_signal(signal.SIGKILL)
    assert workers[host][1].wait(timeout=10) == -signal.SIGKILL

    marker = f"copy {instance} restored on node"
    wait_for("the successor to restore the copy",
             lambda: any(marker in fixture.log(tag) for node, (tag, _) in workers.items() if node != host), 45)
    assert int(fixture.query(revision_sql, databases[0])) > revision

    def recovered():
        after = [log.rsplit("[new world] map 489 ", 1)[1] for log in logs()
                 if log.count("[new world] map 489 ") == 2]
        if len(after) == 2 and all("[initial battlefield states] 489: " in log for log in after):
            return after

    after = wait_for("both original gateway connections to resume in the match", recovered, 22)
    for log in after:
        states = ast.literal_eval(log.split("[initial battlefield states] 489: ", 1)[1].splitlines()[0])
        assert states[1581] == 1 and states[1582] == 0 and states[1546] == (0xFFFFFFFF if drop else 1), log[-4000:]
    resume.touch()
    def captured_again():
        log = recovered()[0]
        return "objectives=[1, 0]" in log and "objectives=[2, 0]" in log and "[world state] 1581=2" in log

    wait_for("the original score and the second capture", captured_again, 25)
    if drop:
        assert dropped and f"use 179786 ({dropped[-1]})" in recovered()[0], recovered()[0][-4000:]
    assert all(f"copy {visible_id} in progress" in log for visible_id, log in zip(visible_ids, recovered()))
    for side, name in enumerate(names):
        assert fixture.query("SELECT b.instance_id FROM character_battleground_data b "
                             f"JOIN characters c USING (guid) WHERE c.name='{name}'",
                             databases[side if cross_realm else 0]) == str(instance)
    finish.touch()
    for i, process in enumerate(battle):
        if process.wait(timeout=30):
            raise RuntimeError(logs()[i][-4000:])
    print(f"PASS: killed worker {host}, resumed copy {instance} at 1–0 with its "
          f"{'dropped' if drop else 'carried'} flag intact, and captured again on the same connections")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cross-realm", action="store_true", help="kill the shared battlegroup host and recover on its standby")
    args = parser.parse_args()
    run_test("cross-realm-match-recovery" if args.cross_realm else "match-recovery",
             lambda fixture: run(fixture, args.cross_realm))
