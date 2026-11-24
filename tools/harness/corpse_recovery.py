#!/usr/bin/env python3
"""Kill the dungeon worker before or partway through looting Gerstahn."""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import BOSS, MAP, open_party, start_cluster, wait


def run(fixture, phase):
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True)
    guid, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE map={MAP} "
                                  f"AND id={BOSS} ORDER BY guid LIMIT 1", fixture.base["world_database"]).split()
    room = f"worldport:{MAP}:{float(x) + 1}:{y}:{z}"
    kill, claim, vote, resume, finish = (fixture.directory / name for name in ("kill", "claim", "vote", "resume", "finish"))
    during_roll = phase == "roll"
    first_claim = ()
    if phase == "claimed":
        first_claim = (wait(claim), "loot:1")
    elif during_roll:
        first_claim = (wait(claim), "loot:0", wait(vote), "rollcast:2")
    actions = [
        (f"lootmethod:{3 if during_roll else 0}", room, wait(kill), f"attack:{BOSS}", f"targetnpc:{BOSS}", "cmd:.kill",
         *first_claim, wait(resume), *(() if during_roll else ("loot",)), wait(finish), "logout"),
        (room, *((wait(resume), "rollcast:1") if during_roll else ()), wait(finish), "logout"),
    ]
    copy, logs, clients = open_party(fixture, characters, names, leader, client, nodes, True, actions)
    arrival = f"{float(x) + 1:.1f} {float(y):.1f} {float(z):.1f}"
    wait_for("both clients at the boss", lambda: all(f"[teleport] to {arrival};" in log for log in logs()), 12)
    kill.touch()

    def corpse():
        return fixture.query(f"SELECT expires_at,state FROM dmangos_instance_corpse "
                             f"WHERE instance={copy} AND spawn={guid}", characters)

    def rewards(owner):
        rows = fixture.query(f"SELECT itemEntry,SUM(count) FROM item_instance WHERE owner_guid={owner} "
                             "GROUP BY itemEntry", characters)
        return {int(entry): int(count) for entry, count in (row.split() for row in rows.splitlines())}

    starting_items = rewards(leader)
    original = wait_for("the unopened corpse saved in MariaDB", corpse, 20)
    hosts = [tag for tag in nodes if tag != "node4" and all(
        f"'{name}' teleported to map {MAP} (" in fixture.log(tag) for name in names)]
    if len(hosts) != 1:
        raise RuntimeError(f"expected one instance worker, found {hosts}")
    host, = hosts
    if phase == "claimed":
        claim.touch()
        wait_for("the first award and the remaining corpse saved",
                 lambda: corpse() != original and rewards(leader) != starting_items, 12)
    if during_roll:
        claim.touch()
        offer = r"\[roll offer\] (0x[\da-f]+) slot (\d+) item (\d+)"
        wait_for("both original roll prompts", lambda: all(re.search(offer, log) for log in logs()), 12)
        roll_guid, slot, item = re.search(offer, logs()[0]).groups()
        rolled_item = int(item)
        ballot = corpse()
        vote.touch()
        wait_for("the greed vote recorded before killing the worker", lambda: corpse() != ballot, 12)
    saved = corpse()
    offsets = list(map(len, logs()))
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        parts = [log[offset:] for log, offset in zip(logs(), offsets)]
        if all(f"[new world] map {MAP} " in log and re.search(rf"\[creature\] {BOSS} guid {guid}: .*health 0,", log)
               for log in parts):
            return parts

    wait_for("both existing sockets to see the original corpse", recovered, 42)
    assert corpse() == saved
    if during_roll:
        prompt = rf"\[roll offer\] {roll_guid} slot {slot} item {rolled_item}"
        wait_for("the original prompt replayed to the member who had not voted",
                 lambda: recovered() and re.search(prompt, recovered()[1]), 8)
        assert not re.search(prompt, recovered()[0]), "a recorded vote must not be requested again"
    resume.touch()
    if during_roll:
        member = fixture.query(f"SELECT guid FROM characters WHERE name='{names[1]}'", characters)
        wait_for("the original roll's winner to receive exactly one item",
                 lambda: rewards(member).get(rolled_item) == 1, 14)
        assert rewards(leader).get(rolled_item, 0) == 0
    else:
        wait_for("the original corpse emptied", lambda: not corpse() and rewards(leader) != starting_items, 14)
        expected = {}
        for item, count in re.findall(r"loot slot \d+: item (\d+) x(\d+)", logs()[0]):
            expected[int(item)] = int(count)
        got = rewards(leader)
        assert len(expected) >= 2 and all(got.get(entry, 0) - starting_items.get(entry, 0) == count
                                          for entry, count in expected.items())
    assert fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={copy}", characters) == "2"
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=26):
            raise RuntimeError(logs()[i][-3000:])
    when = {"unopened": "before opening", "claimed": "after the first claim", "roll": "with a roll in progress"}[phase]
    print(f"PASS: killed {host} {when}, restored both sockets to copy {copy}, and paid each tested award once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    phases = parser.add_mutually_exclusive_group()
    phases.add_argument("--after-claim", dest="phase", action="store_const", const="claimed")
    phases.add_argument("--during-roll", dest="phase", action="store_const", const="roll")
    parser.set_defaults(phase="unopened")
    args = parser.parse_args()
    run_test(f"boss-corpse-{args.phase}", lambda fixture: run(fixture, args.phase))
