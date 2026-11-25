#!/usr/bin/env python3
"""Kill a battleground host and continue the same match on the original gateway connections."""

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


MAPS = {
    "warsong": (489, "warsongGulch", (14981, 2804)),
    "arathi": (529, "arathiBasin", (15008, 15007)),
    "alterac": (30, "alteracValley", (7410, 347)),
}


def run(fixture, cross_realm=False, battleground="warsong", finish_phase=None):
    map_id, type_name, masters = MAPS[battleground]
    cross_realm_arathi = cross_realm and battleground == "arathi"
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
            config = dict(fixture.base, realm_id=i+1, login_database=login, character_database=database, idle_timeout=360,
                          port=ports[8*i+node-1], bind_address="127.0.0.1", write_log=tag+".writes")
            if finish_phase:
                config["battleground_score_statistics"] = True
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
        def standby_ready():
            if workers[2][1].poll() is not None:
                raise RuntimeError(fixture.log("standby")[-2000:])
            return fixture.log("standby").count("listening on") == 4

        wait_for("standby listening in both realms", standby_ready, 55)

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
    fixture.grant_admins(login)
    fixture.start("auth", [AUTH, "-c", auth_path])
    wait_for("auth listening", lambda: "listening on" in fixture.log("auth"), 10)

    def client(label, side, *actions):
        i = side if cross_realm else 0
        env = dict(os.environ, REALM=realms[i], WORLD=f"127.0.0.1:{ports[8*i+3]}",
                   DMANGOS_TEST_WAITFILE_SECONDS="165")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[-1]),
                                     accounts[side], password, *actions], env=env)

    world_db = fixture.base["world_database"]
    for side, name in enumerate(names):
        race = 1 if side == 0 else 2
        class_id = 8 if cross_realm_arathi and side == 0 else 1
        label = f"create{side}"
        if client(label, side, "enum", f"create:{name}:{race}:{class_id}", "drop").wait(timeout=25):
            raise RuntimeError(fixture.log(label))
        x, y, z = fixture.query("SELECT position_x,position_y,position_z FROM creature "
                                f"WHERE id={masters[side]} AND map=0 LIMIT 1", world_db).split()
        fixture.query(f"UPDATE characters SET level=60,map=0,position_x={x},position_y={y},position_z={z} "
                      f"WHERE name='{name}'", databases[side if cross_realm else 0])
        if finish_phase == "after" and side == 1:
            db = databases[side if cross_realm else 0]
            player = int(fixture.query(f"SELECT guid FROM characters WHERE name='{name}'", db))
            occupied = set(map(int, fixture.query(
                f"SELECT slot FROM character_inventory WHERE guid={player} AND bag=0", db).split()))
            for slot in range(23, 39):
                if slot not in occupied:
                    item = 900000 + slot
                    fixture.query("INSERT INTO item_instance (guid,owner_guid,itemEntry,charges,enchantments) VALUES "
                                  f"({item},{player},4540,'0 0 0 0 0',''); "
                                  "INSERT INTO character_inventory (guid,bag,slot,item,item_template) VALUES "
                                  f"({player},0,{slot},{item},4540)", db)

    def port_to(table, entry):
        x, y, z = fixture.query(f"SELECT position_x,position_y,position_z FROM {table} "
                                f"WHERE id={entry} AND map={map_id} ORDER BY guid LIMIT 1", world_db).split()
        return f"worldport:{map_id}:{float(x)+1}:{y}:{z}"

    def visible_pickups(log):
        return stables_pickups.keys() & {
            tuple(map(int, match)) for match in re.findall(r"\[game object\] (\d+) guid (\d+):", log)
        }

    join, force, accept, play, next_objective, resume, finish = (fixture.directory / name for name in
        ("join", "force", "accept", "play", "next-objective", "resume", "finish"))
    before_crash = [[], []]
    after_crash = [[], []]
    win_match = fixture.directory / "win-match"
    drop = battleground == "warsong" and cross_realm
    if battleground == "warsong":
        flag_room = port_to("gameobject", 179831)
        triggers = (Path(fixture.base["data_dir"]) / "dbc" / "AreaTrigger.dbc").read_bytes()
        count, fields, size, _ = struct.unpack_from("<4I", triggers, 4)
        assert fields >= 5
        capture_point = next(struct.unpack_from("<3f", triggers, start + 8)
                             for start in range(20, 20 + count * size, size)
                             if struct.unpack_from("<II", triggers, start) == (3646, map_id))
        capture = f"worldport:{map_id}:" + ":".join(map(str, capture_point))
        before_crash[0] = [flag_room, "usego:179831", capture, "trigger:3646", "listen:24", flag_room, "usego:179831"]
        if drop:
            before_crash[0].append("cancelaura:23333")
            after_crash[0] += [flag_room, "usego:179786"]
        after_crash[0] += ["bgstatus", "pvplog:scores", capture, "trigger:3646", "pvplog:scores"]
    elif battleground == "arathi":
        before_crash[0] = [port_to("gameobject", 180087), "usego:180087", f"waitfile:{next_objective}",
                           port_to("gameobject", 180089), "usego:180089", "pvplog:scores"]
        after_crash[0] = ["bgstatus", "pvplog:scores"]
    elif battleground == "alterac":
        tower = port_to("gameobject", 178943)
        before_crash[0] = ["cmd:.cheat god", port_to("creature", 11657), "targetnpc:11657", "cmd:.kill",
                           tower, "usego:178943", "pvplog:scores"]
        after_crash[0] = ["bgstatus", "pvplog:scores", port_to("creature", 13078)]
        after_crash[1] = ["bgstatus", "pvplog:scores", f"waitfile:{next_objective}",
                          tower, "usego:178940", "pvplog:scores"]
        if finish_phase:
            before_crash[0] += [f"waitfile:{win_match}", port_to("creature", 11946), "targetnpc:11946", "cmd:.kill"]
            after_crash = [["pvplog:scores"], ["pvplog:scores"]]
    if not after_crash[1]:
        after_crash[1] = ["bgstatus", "pvplog:scores"]
    if cross_realm_arathi:
        # Identify just the Stables variants, even if the clients also visit another power-up pad.
        rows = fixture.query("SELECT pickup.id,pickup.guid,t.data3,pickup.position_x,pickup.position_y,pickup.position_z "
                             "FROM gameobject pickup JOIN gameobject_template t ON t.entry=pickup.id "
                             "JOIN gameobject banner ON banner.map=pickup.map AND banner.id=180087 "
                             "WHERE pickup.map=529 AND pickup.id IN (179871,179904,179905) "
                             "AND POW(pickup.position_x-banner.position_x,2) "
                             "+ POW(pickup.position_y-banner.position_y,2) < 2500", world_db)
        stables_pickups = {}
        positions = set()
        for line in rows.splitlines():
            entry, guid, spell, *position = line.split()
            stables_pickups[int(entry), int(guid)] = int(spell)
            positions.add(tuple(map(float, position)))
        assert len(stables_pickups) == 3 and len(positions) == 1, rows
        (px, py, pz), = positions
        take_pickup = fixture.directory / "take-pickup"
        stables = port_to("gameobject", 180087)
        _, _, x, y, z = stables.split(":")
        spells = [stables, "listen:2"] + ["castplayer:133", "listen:2.5"] * 3
        melee = [f"worldport:{map_id}:{float(x)+2}:{y}:{z}:3.14159", "listen:2", "attackplayer",
                 "listen:7", "stopattack"]
        for actions in (before_crash, after_crash):
            actions[0] = ["bgstatus", *spells, *actions[0]]
            actions[1] = ["bgstatus", *melee, *actions[1]]
        after_crash[0] += [f"waitfile:{take_pickup}", f"worldport:{map_id}:{px+5}:{py}:{pz}",
                           f"move:{px}:{py}:{pz}"]

    def check_combat(read_logs):
        def client_kept_columns(log):
            if "battlefield status\n" not in log:
                return False
            reply = log.split("battlefield status\n", 1)[1]
            statuses = re.findall(r"\[battlefield status\] slot \d+: (.+)", reply)
            return len(statuses) >= 3 and statuses[0] == statuses[1] == "none" and "in progress" in statuses[2]

        def verified():
            parts = read_logs()
            if not parts or not all(client_kept_columns(log) for log in parts):
                return False
            return (re.search(r"\[spell damage\] 133: [1-9]\d* to", parts[0])
                    and re.search(r"\[swing\] \d+ -> \d+: (?:hit|crit|block) for [1-9]\d*", parts[1]))

        wait_for("both clients retaining objective columns and taking cross-realm damage without /pvp", verified, 20)

    battle = []
    for side, name in enumerate(names):
        actions = [f"login:{name}"]
        if cross_realm_arathi and side == 1:
            actions += ["cmd:.character increaseweaponskill 300"]
        actions += [f"waitfile:{join}", f"bgjoin:{masters[side]}:{map_id}", f"waitfile:{force}"]
        if side == 0:
            actions += ["cmd:.battleground forcestart"]
        actions += [f"waitfile:{accept}", f"bgport:{map_id}:1", f"waitfile:{play}", *before_crash[side],
                    f"waitfile:{resume}", *after_crash[side], f"waitfile:{finish}"]
        actions += ["drop"] if cross_realm_arathi else [f"bgleave:{map_id}", "listen:1", "logout"]
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
    visible_ids = [re.search(rf"map {map_id} copy (\d+) in progress", log)[1] for log in logs()]

    def started():
        for node, (tag, _) in workers.items():
            found = re.search(rf"battleground: {type_name} \(copy (\d+)\) begins", fixture.log(tag))
            if found:
                return node, int(found[1])

    host, instance = wait_for(f"{type_name} to start", started, 140)
    play.touch()
    if cross_realm_arathi:
        check_combat(logs)
        blue_seen, red_seen = map(visible_pickups, logs())
        assert len(blue_seen) == 1 and blue_seen == red_seen, (blue_seen, red_seen)
        active_pickup, = blue_seen
    dropped = []
    if battleground == "warsong":
        score_marker = "[world state] 1581=1"
        flag_marker = "[world state] 1546=4294967295" if drop else "[world state] 1546=1"
        wait_for("first capture", lambda: score_marker in logs()[0], 25)
        wait_for("second objective action", lambda: flag_marker in logs()[0].split(score_marker, 1)[1], 45)
        if drop:
            dropped = wait_for("the dropped flag's GUID",
                               lambda: re.findall(r"\[game object\] 179786 guid (\d+)", logs()[0]), 3)
        expected = {1581: 1, 1582: 0, 1546: 0xFFFFFFFF if drop else 1}
    elif battleground == "arathi":
        wait_for("Stables held and producing resources", lambda: "[world state] 1776=10" in logs()[0], 85)
        next_objective.touch()
        wait_for("Farm assaulted and two assaults on the scoreboard",
                 lambda: all(s in logs()[0] for s in ("[world state] 1774=1", "objectives=[2, 0]")), 12)
        wait_for("Alliance reaching exactly 30 resources", lambda: "[world state] 1776=30" in logs()[0], 32)
        expected = {1776: 30, 1777: 0, 1779: 1, 1767: 1, 1774: 1, 1772: 0}
    elif battleground == "alterac":
        wait_for("Irondeep taken and Iceblood Tower assaulted",
                 lambda: all(s in logs()[0] for s in ("[world state] 1358=1", "[world state] 1390=1",
                                                       "objectives=[0, 0, 1, 0, 1, 0, 0]")), 28)
        contested_banner = wait_for("Iceblood Tower's contested banner",
            lambda: re.search(r"\[game object\] 178940 guid (\d+)", logs()[0]), 5)[1]
        assert "saveInstanceRespawn" not in fixture.log(workers[host][0])
        assert fixture.query(f"SELECT COUNT(*) FROM creature_respawn WHERE instance={instance}", databases[0]) == "0"
        expected = {1358: 1, 1360: 0, 1390: 1, 1385: 0}
    revision_sql = f"SELECT revision FROM dmangos_bg_match_checkpoint WHERE realm=1 AND instance={instance} AND state <> ''"
    blocked_connection = None
    if finish_phase:
        first = databases[0]
        if finish_phase != "after":
            event = ("BEFORE INSERT ON dmangos_bg_result" if finish_phase == "before"
                     else "BEFORE INSERT ON character_honor_cp")
            fixture.query(f"CREATE TRIGGER bg_finish_hold {event} FOR EACH ROW SET @bg_finish_hold = SLEEP(60)", first)
        win_match.touch()
        if finish_phase == "after":
            wait_for("both reward transactions to commit",
                     lambda: all(fixture.query(f"SELECT COUNT(*) FROM dmangos_bg_reward WHERE instance={instance} "
                                                "AND paid=TRUE", db) == str(1 if cross_realm else 2) for db in databases), 20)
        else:
            schema = first.rsplit(";", 1)[-1]
            blocked_connection = wait_for("the worker to reach the intended transaction",
                lambda: fixture.query("SELECT ID FROM information_schema.PROCESSLIST "
                                      f"WHERE DB='{schema}' AND STATE='User sleep'"), 20)
            assert blocked_connection.isdecimal()
            assert fixture.query(f"SELECT COUNT(*) FROM dmangos_bg_reward WHERE instance={instance} AND paid=TRUE",
                                 first) == "0"
            if finish_phase == "before":
                assert fixture.query(f"SELECT LEFT(state, 2) FROM dmangos_bg_match_checkpoint WHERE instance={instance}",
                                     first) == "F:"
    revision = int(fixture.query(revision_sql, databases[0]))
    workers[host][1].send_signal(signal.SIGKILL)
    assert workers[host][1].wait(timeout=10) == -signal.SIGKILL
    if blocked_connection:
        if fixture.query(f"SELECT ID FROM information_schema.PROCESSLIST WHERE ID={blocked_connection}"):
            fixture.query(f"KILL CONNECTION {blocked_connection}")
        fixture.query("DROP TRIGGER bg_finish_hold", databases[0])

    marker = f"copy {instance} restored on node"
    wait_for("the successor to restore the copy",
             lambda: any(marker in fixture.log(tag) for node, (tag, _) in workers.items() if node != host), 45)
    assert int(fixture.query(revision_sql, databases[0])) > revision

    def recovered():
        map_entry = f"[new world] map {map_id} "
        after = [log.rsplit(map_entry, 1)[1] for log in logs() if log.count(map_entry) == 2]
        if len(after) == 2 and all(f"[initial battlefield states] {map_id}: " in log for log in after):
            return after

    after = wait_for("both original gateway connections to resume in the match", recovered, 22)
    for log in after:
        states = ast.literal_eval(log.split(f"[initial battlefield states] {map_id}: ", 1)[1].splitlines()[0])
        assert {key: states.get(key) for key in expected} == expected, log[-4000:]
    resume.touch()
    if cross_realm_arathi:
        check_combat(recovered)
    if finish_phase:
        wait_for("both final scoreboards on the original connections",
                 lambda: all("[scoreboard] over, winner 1, 2 players" in log for log in recovered()), 16)
        wait_for("both home databases to pay the reward",
                 lambda: all(fixture.query(f"SELECT COUNT(*) FROM dmangos_bg_reward WHERE instance={instance} "
                                            "AND paid=TRUE", db) == str(1 if cross_realm else 2) for db in databases), 20)
        weekend = "Call to Arms: Alterac Valley!) starts" in fixture.log(workers[host][0])
        expected_standing = (687, 108) if weekend else (458, 72)
        expected_honor = (1584, 792) if weekend else (792, 0)
        for side, name in enumerate(names):
            db = databases[side if cross_realm else 0]
            player = fixture.query(f"SELECT guid FROM characters WHERE name='{name}'", db)
            assert fixture.query(f"SELECT SUM(count) FROM item_instance WHERE owner_guid={player} AND itemEntry=20560",
                                 db) == ("3" if side == 0 else "1")
            assert fixture.query(f"SELECT COUNT(*) FROM mail_items WHERE receiver={player} AND item_template=20560",
                                 db) == ("1" if finish_phase == "after" and side == 1 else "0")
            faction = 730 if side == 0 else 729
            standing = int(fixture.query(f"SELECT standing FROM character_reputation WHERE guid={player} AND faction={faction}", db))
            assert standing == expected_standing[side], standing
            honor_rows, honor = fixture.query(
                f"SELECT COUNT(*),IFNULL(SUM(honor),0) FROM character_honor_cp WHERE guid={player} AND victim_type=0",
                db).split()
            assert (int(honor_rows), float(honor)) == (int(expected_honor[side] > 0), expected_honor[side])
            assert fixture.query(f"SELECT COUNT(*) FROM dmangos_bg_result WHERE instance={instance} AND winner=1", db) == "1"
            assert fixture.query("SELECT COUNT(*) FROM pvpstats_battlegrounds WHERE winner_team=1", db) == "1"
            logged_score = fixture.query(
                f"SELECT score_bonus_honor, attr_3, attr_5 FROM pvpstats_players WHERE character_guid={player}", db)
            saved_score = (expected_honor[side], 1 - side, 1 - side)
            assert tuple(map(int, logged_score.split())) == saved_score, logged_score
        result = f"the final scoreboard and one payout to each player, after killing the worker {finish_phase} payout"
    elif battleground == "warsong":
        def captured_again():
            log = recovered()[0]
            return all(s in log for s in ("objectives=[1, 0]", "objectives=[2, 0]", "[world state] 1581=2"))

        wait_for("the original score and the second capture", captured_again, 25)
        if drop:
            assert f"use 179786 ({dropped[-1]})" in recovered()[0], recovered()[0][-4000:]
        result = f"1–0 with its {'dropped' if drop else 'carried'} flag intact, then scored again"
    elif battleground == "arathi":
        def arathi_continued():
            log = recovered()[0]
            return all(s in log for s in ("objectives=[2, 0]", "[world state] 1776=40",
                                          "[world state] 1772=1", "[world state] 1779=2"))

        wait_for("resources to keep ticking and the pending Farm capture to finish", arathi_continued, 53)
        result = "30–0 resources with Stables held and Farm still contested, then accrued resources and finished capturing Farm"
        if cross_realm_arathi:
            result += "; melee and spell damage worked across realms and status kept the objective columns before and after takeover"
            assert [visible_pickups(log) for log in recovered()] == [{active_pickup}] * 2
            take_pickup.touch()
            entry, spawn = active_pickup
            reported_guid = (entry << 24 | spawn) & 0xFFFFFFFF  # testclient prints the low 32 bits on removal
            spell = stables_pickups[active_pickup]

            def collected():
                _, moved, log = recovered()[0].partition(f"moved to {px} {py} {pz}")
                if not moved or f"[spell go] {spell} by" not in log or "[aura duration]" not in log:
                    return False
                removed = re.findall(r"\[out of range\] ([\d, ]+)", log)
                return any(str(reported_guid) in group.split(", ") for group in removed)

            wait_for("walking onto the original Stables pickup to cast its spell and despawn it", collected, 10)
            result += "; only the original Stables pickup appeared and it triggered on approach"
    elif battleground == "alterac":
        wait_for("the original scoreboard and the Alliance mine boss on the recovered map",
                 lambda: all(s in recovered()[0] for s in ("objectives=[0, 0, 1, 0, 1, 0, 0]", "[creature] 13078 guid")), 15)
        next_objective.touch()
        wait_for("Horde defending the original, already-contested tower",
                 lambda: all(s in recovered()[1] for s in (f"use 178940 ({contested_banner})", "[world state] 1385=1",
                                                           "objectives=[0, 0, 0, 1, 0, 0, 0]")), 15)
        result = "the original mine and tower scores, with Irondeep held and Iceblood Tower contested, then defended the tower"
    if not finish_phase:
        assert all(f"copy {visible_id} in progress" in log for visible_id, log in zip(visible_ids, recovered()))
    for side, name in enumerate(names):
        assert fixture.query("SELECT b.instance_id FROM character_battleground_data b "
                             f"JOIN characters c USING (guid) WHERE c.name='{name}'",
                             databases[side if cross_realm else 0]) == str(instance)
    finish.touch()
    for i, process in enumerate(battle):
        if process.wait(timeout=30):
            raise RuntimeError(logs()[i][-4000:])
    if cross_realm_arathi:
        wait_for("both players to be offline in the same match", lambda: all(
            fixture.query(f"SELECT online FROM characters WHERE name='{name}'", db) == "0"
            for name, db in zip(names, databases)), 15)
        done = fixture.directory / "relogin-done"
        relogged = [client(f"relogin{side}", side, f"login:{name}", f"waitfile:{done}",
                           f"bgleave:{map_id}", "listen:1", "logout") for side, name in enumerate(names)]

        def initial_match_states():
            for side, (name, db) in enumerate(zip(names, databases)):
                log = fixture.log(f"relogin{side}")
                frames = re.findall(rf"\[initial battlefield states\] {map_id}: (.+)", log)
                if not frames:
                    return False
                states = ast.literal_eval(frames[-1])
                if (states.get(1779), states.get(1778), states.get(1767), states.get(1772)) != (2, 0, 1, 1):
                    return False
                assert states.get(1776, 0) >= 40 and states.get(1777) == 0
                assert fixture.query("SELECT b.instance_id FROM character_battleground_data b "
                                     f"JOIN characters c USING (guid) WHERE c.name='{name}'", db) == str(instance)
            return True

        wait_for("both fresh gateway logins to receive the same match's two Alliance bases", initial_match_states, 15)
        done.touch()
        for side, process in enumerate(relogged):
            if process.wait(timeout=30):
                raise RuntimeError(fixture.log(f"relogin{side}")[-4000:])
        result += "; both fresh logins received the full base and resource state"
    print(f"PASS: killed worker {host}, resumed {type_name} copy {instance} on the same connections with {result}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map", choices=MAPS, default="warsong", help="battleground to exercise")
    parser.add_argument("--cross-realm", action="store_true", help="kill the shared battlegroup host and recover on its standby")
    parser.add_argument("--finish-phase", choices=("before", "during", "after"), help="kill around Alterac's final payout")
    args = parser.parse_args()
    if args.finish_phase and args.map != "alterac":
        parser.error("--finish-phase uses --map alterac")
    prefix = "cross-realm" if args.cross_realm else "same-realm"
    suffix = args.finish_phase or "recovery"
    run_test(f"{prefix}-{args.map}-{suffix}", lambda fixture: run(fixture, args.cross_realm, args.map, args.finish_phase))
