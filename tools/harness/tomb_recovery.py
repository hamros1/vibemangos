#!/usr/bin/env python3
"""Check Blackrock Depths' Tomb of the Seven after a hard worker crash."""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import MAP, open_party, start_cluster, wait


DWARVES = (9035, 9038, 9040, 9037, 9036, 9034, 9039)
ENTRANCE = 170576
EXIT = 170577
CHEST = 169243
OPENING = 3365


def run(fixture, crash_when):
    # Keep the spawns, templates and scripts, with all seven on the same floor for scripted clients.
    world = fixture.world_with_writable_tables("creature")
    for offset, dwarf in enumerate(DWARVES[:-1], 1):
        fixture.query(f"UPDATE creature SET position_x={1281.14 - offset}, position_y=-282.151, position_z=-78.1359 "
                      f"WHERE map={MAP} AND id={dwarf}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    creatures = fixture.query(f"SELECT id,guid,position_x,position_y,position_z FROM creature WHERE map={MAP} "
                              f"AND id IN ({','.join(map(str, DWARVES))})", world)
    spawns, visits, arrivals = {}, {}, {}
    for row in creatures.splitlines():
        entry, guid, x, y, z = row.split()
        spawns[int(entry)] = int(guid)
        visits[int(entry)] = f"worldport:{MAP}:{float(x) + 1}:{y}:{z}"
        arrivals[int(entry)] = f"worldport {MAP} {float(x) + 1} {float(y)} {float(z)}"
    chest_spawn, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM gameobject "
                                        f"WHERE map={MAP} AND id={CHEST}", world).split()
    reward_room = f"worldport:{MAP}:{float(x) + 1}:{y}:{z}"
    start, resume, claim, open_chest, finish = (fixture.directory / name for name in
                                               ("challenge", "resume", "claim", "open", "finish"))
    rounds = DWARVES[:2] if crash_when == "wave" else DWARVES
    attacks, follow = [], []
    kill_now = {dwarf: fixture.directory / f"fight-{dwarf}" for dwarf in rounds}
    meet = {dwarf: fixture.directory / f"meet-{dwarf}" for dwarf in rounds}
    for index, dwarf in enumerate(rounds):
        if index == 1 and crash_when == "wave":
            attacks.append(wait(resume))
        attacks.extend((visits[dwarf], wait(kill_now[dwarf]), f"killpack:{dwarf}"))
        follow.extend((wait(meet[dwarf]), visits[dwarf]))
    open_reward = f"castgo:{OPENING}:{CHEST}"
    claim_first = (wait(claim), open_reward + ":1") if crash_when == "claimed" else ()
    leader_reward = (reward_room, *claim_first, wait(open_chest), open_reward) if crash_when != "wave" else ()
    member_reward = (reward_room, wait(open_chest), "query") if crash_when != "wave" else ()
    actions = [
        ("lootmethod:0", visits[DWARVES[-1]], f"npc:{DWARVES[-1]}", "gossip", wait(start), "select:0",
         *attacks, *leader_reward, wait(finish), "logout"),
        (reward_room, *follow, *member_reward, wait(finish), "logout"),
    ]
    copy, logs, clients = open_party(fixture, characters, names, leader, client, nodes, True, actions)
    wait_for("both party members in the Tomb", lambda: all(f"[game object] {EXIT}" in log for log in logs()), 15)
    wait_for("free-for-all loot for the reward probe",
             lambda: fixture.query(f"SELECT lootMethod FROM groups WHERE leaderGuid={leader}", characters) == "0", 10)
    checkpoint = f"instance {copy} of map {MAP} saved an encounter checkpoint"
    start.touch()

    def defeated(dwarf):
        return fixture.query(f"SELECT COUNT(*) FROM creature_respawn WHERE instance={copy} AND guid={spawns[dwarf]}",
                             characters) == "1"

    def reward():
        return fixture.query(f"SELECT CONCAT(expires_at, ':', LENGTH(loot)) FROM dmangos_instance_chest "
                             f"WHERE instance={copy} AND spawn={chest_spawn}", characters)

    def payouts():
        return dict(tuple(map(int, row.split())) for row in fixture.query(
            f"SELECT itemEntry,SUM(count) FROM item_instance WHERE owner_guid={leader} "
            "AND itemEntry BETWEEN 11920 AND 11929 GROUP BY itemEntry", characters).splitlines())

    def crash():
        host = wait_for("the Tomb's checkpoint", lambda: next(
            (node for node in nodes if checkpoint in fixture.log(node)), None), 12)
        offsets = list(map(len, logs()))
        nodes[host].send_signal(signal.SIGKILL)
        assert nodes[host].wait(timeout=10) == -signal.SIGKILL

        def recovered():
            slices = [log[offset:] for log, offset in zip(logs(), offsets)]
            if all(f"[new world] map {MAP} " in log and "[group list] party" in log for log in slices):
                return slices

        return host, wait_for("the same gateway connections to recover", recovered, 35)

    host = None
    for index, dwarf in enumerate(rounds):
        if index == 1 and crash_when == "wave":
            host, after = crash()
            first, second = DWARVES[:2]
            for log in after:
                assert f"[creature] {first} guid {spawns[first]}" not in log
                assert f"[creature] {second} guid {spawns[second]}" in log
                assert re.search(rf"\[game object\] {ENTRANCE} guid \d+: .*state 1", log)
            resume.touch()
        meet[dwarf].touch()
        wait_for(f"dwarf {dwarf} fighting", lambda: f"[attack start] {spawns[dwarf]} ->" in logs()[0], 34)
        # Move both characters beside the dwarf before using the referee's kill command.
        if dwarf != DWARVES[-1]:
            wait_for(f"both players beside dwarf {dwarf}", lambda: all(
                arrivals[dwarf] in log and "[teleport]" in log.rsplit(arrivals[dwarf], 1)[1]
                for log in logs()), 10)
        kill_now[dwarf].touch()
        wait_for(f"dwarf {dwarf}'s durable death", lambda: defeated(dwarf), 10)

    if crash_when == "wave":
        wait_for("the next round after recovery", lambda: f"[attack start] {spawns[DWARVES[2]]} ->" in logs()[0], 10)
    else:
        unopened = wait_for("the unopened chest's durable deadline", reward, 8)
        assert unopened.endswith(":0")
        paid = {}
        if crash_when == "claimed":
            claim.touch()
            paid = wait_for("exactly one chest item saved before the crash", payouts, 15)
            assert sum(paid.values()) == 1
        checkpointed_chest = reward()
        host, after = crash()
        assert reward() == checkpointed_chest
        for log in after:
            assert re.search(rf"\[game object\] {EXIT} guid \d+: .*state 0", log)
            assert f"[game object] {CHEST} guid {chest_spawn}:" in log
            assert all(f"[creature] {dwarf} guid {spawns[dwarf]}:" not in log for dwarf in DWARVES)
        open_chest.touch()

        def both_items():
            items = payouts()
            if sum(items.values()) == 2:
                return items

        final_payouts = wait_for("both Tomb rewards paid exactly once", both_items, 20)
        assert len(final_payouts) == 2 and all(final_payouts[item] == count for item, count in paid.items())
        assert reward() and not reward().endswith(":0")
    bindings = fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={copy}", characters)
    assert bindings == "2" and all(defeated(dwarf) for dwarf in rounds)
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=30):
            raise RuntimeError(logs()[i][-4000:])
    when = {"wave": "during the fight", "unopened": "before the chest opened", "claimed": "after the first claim"}[crash_when]
    print(f"PASS: Tomb worker {host} died {when}. Both clients stayed in copy {copy}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    crash = parser.add_mutually_exclusive_group()
    crash.add_argument("--after-reward", action="store_const", dest="crash_when", const="unopened",
                       help="crash after Doom'rel, before the chest is opened")
    crash.add_argument("--after-claim", action="store_const", dest="crash_when", const="claimed",
                       help="crash after the first chest item was claimed")
    parser.set_defaults(crash_when="wave")
    args = parser.parse_args()
    run_test("blackrock-depths-tomb", lambda fixture: run(fixture, args.crash_when))
