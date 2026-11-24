#!/usr/bin/env python3
"""Kill the worker between Ring of Law waves and finish the same dungeon on the same sockets."""

import argparse
import json
import os
import re
import signal
import struct
import subprocess
import sys
from pathlib import Path

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for


MAP = 230
BOSS = 9018
KEY = 11140
ENTRANCE = 1466
TRIGGER = 1526
BEASTS = {8925: 4, 8926: 2, 8927: 5, 8928: 3, 8933: 3, 8932: 7}
CHAMPIONS = set(range(9027, 9033))


def start_cluster(fixture, new_party, *, world=None):
    login = fixture.fresh_schema("login", "classicrealmd.sql")
    characters = fixture.fresh_schema("chars", "classiccharacters.sql")
    ports = available_ports(9)
    base = dict(fixture.base, realm_id=1, login_database=login, character_database=characters,
                bind_address="127.0.0.1", idle_timeout=240)
    if world is not None:
        base["world_database"] = world
    seed = fixture.start_world("seed", dict(base, port=ports[0], write_log="seed.writes"))
    wait_for("the seed world", lambda: "listening on" in fixture.log("seed"), 30)

    accounts = ("RINGKEEPER", "RINGWATCHER")
    names = ("Ringkeeper", "Ringwatcher")
    password = "TESTRINGRECOVERY"
    auth = fixture.directory / "auth.json"
    auth.write_text(json.dumps(dict(login_database=login, mysql_library=fixture.base["mysql_library"],
                                   bind_address="127.0.0.1", port=ports[-1], realms_state_update_delay=1)))
    for account in accounts:
        subprocess.run([AUTH, "-c", auth, "account", "create", account, password], cwd=fixture.directory,
                       check=True, timeout=15, stdout=subprocess.DEVNULL)
    fixture.query("UPDATE account SET gmlevel=3", login)
    fixture.start("auth", [AUTH, "-c", auth])
    wait_for("auth listening", lambda: "listening on" in fixture.log("auth"), 15)

    def client(label, side, *actions, node=4):
        env = dict(os.environ, WORLD=f"127.0.0.1:{ports[node-1]}", DMANGOS_TEST_WAITFILE_SECONDS="165")
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(ports[-1]),
                                     accounts[side], password, *actions], env=env)

    guids = []
    for side, name in enumerate(names):
        label = f"create{side}"
        creating = client(label, side, "enum", f"create:{name}:1:1", "drop", node=1)
        if creating.wait(timeout=25) or "(success)" not in fixture.log(label):
            raise RuntimeError(fixture.log(label))
        guids.append(int(wait_for(f"{name} saved", lambda: fixture.query(
            f"SELECT guid FROM characters WHERE name='{name}'", characters), 10)))
    seed.terminate()
    if seed.wait(timeout=25):
        raise RuntimeError("the seed world did not shut down cleanly")
    leader, member = guids
    dbc = (Path(fixture.base["data_dir"]) / "dbc" / "AreaTrigger.dbc").read_bytes()
    count, _, size, _ = struct.unpack_from("<4I", dbc, 4)

    def trigger_position(trigger, map_id):
        return next(struct.unpack_from("<3f", dbc, p+8) for p in range(20, 20+count*size, size)
                    if struct.unpack_from("<II", dbc, p) == (trigger, map_id))

    x, y, z = trigger_position(ENTRANCE, 0)
    fixture.query(f"UPDATE characters SET level=60,health=2000,map=0,position_x={x},position_y={y},position_z={z}",
                  characters)
    if not new_party:
        fixture.query(f"INSERT INTO groups VALUES (1,{leader},0,0,3,{leader},2,0,0,0,0,0,0,0,0,0); "
                      f"INSERT INTO group_member VALUES (1,{leader},0,0),(1,{member},0,0)", characters)
    assert fixture.query("SELECT COUNT(*) FROM instance", characters) == "0"

    roster = [{"node_id": node, "address": f"127.0.0.1:{ports[node+3]}"} for node in (1, 2, 3)]
    nodes = {}
    for node in (1, 2, 3, 4):
        tag = f"node{node}"
        config = dict(base, port=ports[node-1], write_log=f"{tag}.writes")
        config["cluster"] = dict(name="dungeon-recovery", node_id=node, listen_address="127.0.0.1",
                                 listen_port=ports[node+3], voters=roster, gateway=node == 4)
        if node != 4:
            config["cluster"]["vote_file"] = f"{tag}.vote"
        nodes[tag] = fixture.start_world(tag, config)
    wait_for("gateway and its initial lease", lambda: "lease holds" in fixture.log("node4"), 60)

    return characters, names, leader, client, nodes, trigger_position


def open_party(fixture, characters, names, leader, client, nodes, new_party, actions):
    invite, accept, enter, inside = (fixture.directory / name for name in ("invite", "accept", "enter", "inside"))
    assemble_leader = (wait(invite), f"invite:{names[1]}") if new_party else ()
    assemble_member = (wait(accept), "accept") if new_party else ()
    portal = (wait(enter), "cmd:.cheat god", f"trigger:{ENTRANCE}", wait(inside))
    clients = [
        client("party0", 0, f"login:{names[0]}", *assemble_leader, *portal, *actions[0]),
        client("party1", 1, f"login:{names[1]}", *assemble_member, *portal, *actions[1]),
    ]

    def logs():
        output = [fixture.log(f"party{i}") for i in range(2)]
        for i, process in enumerate(clients):
            if process.poll():
                raise RuntimeError(f"party client {i} failed:\n{output[i][-2000:]}")
        return output

    wait_for("both party members logged in", lambda: all("[appears] player" in log for log in logs()), 30)
    wait_for("both players routed from the gateway to workers",
             lambda: all(any(f"'{name}' arrived from another node" in fixture.log(tag)
                             for tag in nodes if tag != "node4") for name in names), 15)
    if new_party:
        invite.touch()
        wait_for("the coordinator to deliver the invite", lambda: "[invited by]" in logs()[1], 12)
        accept.touch()
        wait_for("both clients to see the new party", lambda: all("[group list] party" in log for log in logs()), 12)
    enter.touch()
    wait_for("both players through the real dungeon portal",
             lambda: all(f"[new world] map {MAP} " in log for log in logs()), 20)
    binds = wait_for("both character binds written",
                     lambda: fixture.query("SELECT instance FROM character_instance ORDER BY guid", characters)
                     if fixture.query("SELECT COUNT(*) FROM character_instance", characters) == "2" else "", 12)
    copies = set(map(int, binds.split()))
    assert len(copies) == 1, f"party split between dungeon copies {sorted(copies)}"
    copy, = copies
    assert fixture.query(f"SELECT instance FROM group_instance WHERE leaderGuid={leader}", characters) == str(copy)
    wait_for("both clients to see the same party", lambda: all("[group list] party" in log for log in logs()), 12)
    inside.touch()
    return copy, logs, clients


def wait(flag):
    return f"waitfile:{flag}"


def run(fixture, new_party, active_wave):
    characters, names, leader, client, nodes, trigger_position = start_cluster(fixture, new_party)
    world_db = fixture.base["world_database"]
    boss_guid, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE id={BOSS} "
                                      f"AND map={MAP} ORDER BY guid LIMIT 1", world_db).split()
    boss_room = f"worldport:{MAP}:{float(x)+1}:{y}:{z}"
    boss_arrival = f"[teleport] to {float(x)+1:.1f} {float(y):.1f} {float(z):.1f};"
    arena = trigger_position(TRIGGER, MAP)
    ring = f"worldport:{MAP}:" + ":".join(map(str, arena))
    arena_floor = f"worldport:{MAP}:608.960:-231.322:-53.907"
    checkpoint_floor = f"worldport:{MAP}:608.460:-231.322:-53.907"
    checkpoint_arrival = "608.5 -231.3 -53.9"
    paths = [fixture.directory / name for name in
             ("follow", "start-ring", "move", "first-wave", "second-wave", "resume-wave",
              "champion", "check-boss", "finish")]
    follow, start, move, first, second, resume, champion, check_boss, finish = paths
    kill_beasts = "killpack:" + ":".join(map(str, BEASTS))
    kill_champion = "killpack:" + ":".join(map(str, sorted(CHAMPIONS)))
    first_wave = (kill_beasts.replace("killpack:", "killpack:one:"), wait(resume), kill_beasts) if active_wave else (kill_beasts,)
    actions = [
        (boss_room, f"attack:{BOSS}", f"targetnpc:{BOSS}", "cmd:.kill", "loot",
         ring, wait(start), f"trigger:{TRIGGER}", arena_floor, wait(move), checkpoint_floor, wait(first), *first_wave,
         wait(second), kill_beasts, wait(champion), kill_champion, wait(check_boss), boss_room, "query",
         wait(finish), "logout"),
        (wait(follow), ring, wait(start), arena_floor, wait(move), checkpoint_floor,
         wait(check_boss), boss_room, "query", wait(finish), "logout"),
    ]
    copy, logs, clients = open_party(fixture, characters, names, leader, client, nodes, new_party, actions)

    def creature_guids(log, entries):
        return {int(guid): int(entry) for entry, guid in re.findall(r"\[creature\] (\d+) guid (\d+):", log)
                if int(entry) in entries}

    def durable_key():
        return fixture.query(f"SELECT IFNULL(SUM(count),0) FROM item_instance WHERE itemEntry={KEY}", characters)

    wait_for("Gerstahn's key in the saved inventory", lambda: durable_key() == "1", 30)
    assert fixture.query(f"SELECT COUNT(*) FROM creature_respawn WHERE instance={copy} AND guid={boss_guid}",
                         characters) == "1"
    follow.touch()
    wait_for("both players at the arena", lambda: all("[game object] 161525" in log for log in logs()), 22)
    assert fixture.query(f"SELECT id FROM instance WHERE map={MAP}", characters) == str(copy)
    start.touch()

    def wave(log, exclude=()):
        entries = {guid: entry for guid, entry in creature_guids(log, BEASTS).items() if guid not in exclude}
        if entries and len(set(entries.values())) == 1 and len(entries) == BEASTS[next(iter(entries.values()))]:
            return entries

    original = wait_for("the complete first wave", lambda: wave(logs()[0]), 25)
    move.touch()
    wait_for("both clients moved just before the crash",
             lambda: all(f"[teleport] to {checkpoint_arrival};" in log for log in logs()), 6)
    checkpoint = f"instance {copy} of map {MAP} saved an encounter checkpoint"
    checkpoint_counts = {tag: fixture.log(tag).count(checkpoint) for tag in nodes}
    first.touch()

    def defeated_wave_members():
        dead = {int(guid) & 0xFFFFFF for guid in re.findall(r"\[changes\] (\d+): fields .*?health 0/", logs()[0])}
        defeated = set(original) & dead
        if len(defeated) == (1 if active_wave else len(original)):
            return defeated

    defeated = wait_for("first-wave deaths before the crash", defeated_wave_members, 4)
    host = wait_for("the durable checkpoint after the kills", lambda: next(
        (tag for tag in nodes if fixture.log(tag).count(checkpoint) > checkpoint_counts[tag]), None), 4)
    assert fixture.query(f"SELECT COUNT(*) FROM characters WHERE map={MAP} AND ABS(position_x - 608.460)<0.05",
                         characters) == "2", "the encounter checkpoint saved both players' latest positions"
    offsets = list(map(len, logs()))
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        suffixes = [log[offset:] for log, offset in zip(logs(), offsets)]
        if all(f"[new world] map {MAP} at {checkpoint_arrival};" in log and "[creature] 10096 " in log
               for log in suffixes):
            return suffixes

    after = wait_for("both existing sockets to reload the Ring of Law", recovered, 40)
    wait_for("both recovered clients to see the party roster",
             lambda: all("[group list] party" in log for log in recovered()), 4)
    survivors = {guid: entry for guid, entry in original.items() if guid not in defeated}
    assert all(creature_guids(log, BEASTS) == survivors for log in after), "the first wave resumed with the wrong creatures"
    for log in after:
        assert re.search(r"\[game object\] 161525 guid \d+: .*state 0", log), "east gate failed to reopen"
        assert re.search(r"\[game object\] 161523 guid \d+: .*state 1", log), "entry gate failed to stay closed"

    if active_wave:
        resume.touch()

    def shared_wave():
        leader_wave, member_wave = (wave(log, survivors) for log in recovered())
        if leader_wave and leader_wave == member_wave:
            return leader_wave

    next_wave = wait_for("the scheduled second wave on both clients", shared_wave, 8)
    assert set(original).isdisjoint(next_wave) and set(next_wave.values()) == set(original.values())
    assert fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={copy}", characters) == "2"
    second.touch()
    wait_for("the champion", lambda: creature_guids(recovered()[0], CHAMPIONS), 24)
    champion.touch()
    wait_for("the Ring of Law to finish", lambda: any("the Ring of Law is won" in fixture.log(tag)
                                                    for tag in nodes if tag != host), 12)
    check_boss.touch()
    wait_for("both players back in Gerstahn's room", lambda: all(
        boss_arrival in log and "query time:" in log.rsplit(boss_arrival, 1)[1] for log in recovered()), 14)
    tail = [log.rsplit(boss_arrival, 1)[1] for log in recovered()]
    assert all(not creature_guids(log, {BOSS}) for log in tail), "the looted boss came back"
    assert durable_key() == "1" and fixture.query(f"SELECT COUNT(*) FROM instance WHERE id={copy}", characters) == "1"
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=30):
            raise RuntimeError(logs()[i][-4000:])
    when = "during the first Ring of Law wave" if active_wave else "between Ring of Law waves"
    print(f"PASS: worker {host} died {when}; both original clients finished copy {copy}, "
          "with its boss death and one prison key intact")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--new-party", action="store_true", help="form the party through an in-game invite")
    parser.add_argument("--active-wave", action="store_true", help="kill the worker with part of the first wave still alive")
    args = parser.parse_args()
    run_test("blackrock-depths-recovery", lambda fixture: run(fixture, args.new_party, args.active_wave))
