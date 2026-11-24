#!/usr/bin/env python3
"""Recover an outdoor corpse and finish its original roll on two workers."""

import math
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from group_loot import PRIZE, round_positions


CREATURE, LOOT = 448, 8_910_002


def run(fixture):
    world = fixture.world_with_writable_tables("creature", "creature_template", "creature_loot_template")
    fixture.query(f"UPDATE creature_template SET LootId={LOOT}, MinLootGold=0, MaxLootGold=0 "
                  f"WHERE Entry={CREATURE}; INSERT INTO creature_loot_template (entry,item) VALUES ({LOOT},{PRIZE})",
                  world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    member = int(fixture.query(f"SELECT guid FROM characters WHERE name='{names[1]}'", characters))

    def ownership():
        regions = {}
        for node in (1, 2, 3):
            latest = re.findall(r"this node owns \[([^]]*)\]", fixture.log(f"node{node}"))
            if not latest or not latest[-1]:
                return None
            regions[node] = set(map(int, re.findall(r"\d+", latest[-1])))
        return regions

    map_id, (owner, x, y), (other, member_x, member_y), _ = round_positions(
        fixture.log("node1"), wait_for("all three workers to own regions", ownership, 30))
    # Leave room to spawn and attack the creature inside the same region as the opener.
    distance = math.hypot(x - member_x, y - member_y)
    x += 8 * (x - member_x) / distance
    y += 8 * (y - member_y) / distance
    for guid, px, py in ((leader, x, y), (member, member_x, member_y)):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={px},position_y={py},position_z=200 "
                      f"WHERE guid={guid}", characters)
    invite, accept, kill, vote, resume, finish = (fixture.directory / flag for flag in
                                                  ("invite", "accept", "kill", "vote", "resume", "finish"))
    clients = [
        client("party0", 0, f"login:{names[0]}", "cmd:.cheat god", wait(invite), f"invite:{names[1]}", wait(kill),
               "lootmethod:3", f"cmd:.npc spawn {CREATURE}", f"attack:{CREATURE}", f"targetnpc:{CREATURE}", "cmd:.kill",
               "loot:0", "query", wait(vote), "rollcast:2", wait(finish), "logout"),
        client("party1", 1, f"login:{names[1]}", "cmd:.cheat god", wait(accept), "accept",
               wait(resume), "rollcast:1", "rollcast:1", wait(finish), "logout"),
    ]

    def logs():
        output = [fixture.log(f"party{i}") for i in range(2)]
        for i, process in enumerate(clients):
            if process.poll():
                raise RuntimeError(f"client {i} failed:\n{output[i][-2000:]}")
        return output

    for tag, name, px, py in ((f"node{owner}", names[0], x, y),
                             (f"node{other}", names[1], member_x, member_y)):
        wait_for(f"{name} on {tag}", lambda: f"'{name}' arrived from another node (map {map_id} at "
                                              f"{px:.1f} {py:.1f})" in fixture.log(tag), 20)
    invite.touch()
    wait_for("the other worker's player to receive the party invite", lambda: "[invited by]" in logs()[1], 12)
    accept.touch()
    wait_for("both clients in the same party", lambda: all("[group list] party" in log for log in logs()), 12)
    kill.touch()
    offer = rf"\[roll offer\] (0x[\da-f]+) slot (\d+) item {PRIZE}\b"
    wait_for("the same roll started on both workers", lambda: all(re.search(offer, log) for log in logs()), 15)
    guid, slot = re.search(offer, logs()[0]).groups()
    assert re.search(offer, logs()[1]).groups() == (guid, slot)
    spawn = int(guid, 16) & 0xFFFFFF
    wait_for("the opener to finish reading the loot", lambda: "query time:" in logs()[0], 12)

    def corpse():
        return fixture.query(f"SELECT state FROM dmangos_instance_corpse WHERE instance=0 AND spawn={spawn}", characters)

    ballot = wait_for("the outdoor corpse checkpoint", corpse, 12)
    vote.touch()
    wait_for("the opener's original vote recorded", lambda: corpse() not in ("", ballot), 12)
    offsets = list(map(len, logs()))
    host = nodes[f"node{owner}"]
    host.send_signal(signal.SIGKILL)
    assert host.wait(timeout=10) == -signal.SIGKILL

    def recovered():
        return [log[offset:] for log, offset in zip(logs(), offsets)]

    dead = rf"\[creature\] {CREATURE} guid {spawn}: .*health 0,"
    wait_for("the original opener socket to see the same dead creature",
             lambda: f"[new world] map {map_id} " in recovered()[0] and re.search(dead, recovered()[0]), 42)
    assert not re.search(offer, recovered()[0]), "a recorded vote must not be requested again"
    if "[new world]" in recovered()[1]:
        wait_for("the original pending prompt replayed after the remote player's lease loss",
                 lambda: re.search(offer, recovered()[1]), 16)
    resume.touch()
    wait_for("one copy of the prize awarded to the original remote member", lambda: fixture.query(
        f"SELECT owner_guid,count FROM item_instance WHERE itemEntry={PRIZE}", characters) == f"{member}\t1", 15)
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=26):
            raise RuntimeError(fixture.log(f"party{i}")[-3000:])
    print(f"PASS: killed node {owner} with a vote pending on node {other}; the original corpse and roll "
          "survived on both sockets, with one award in MariaDB")


if __name__ == "__main__":
    run_test("outdoor-corpse-recovery", run)
