#!/usr/bin/env python3
"""Kill the Dire Maul worker during the Dreadsteed ritual and resume on the same sockets."""

import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import open_party, start_cluster, wait


MAP = 429
KEEPER = 14501
JEEVEE = 14500
BELL = 179674
CIRCLE = 179668


def run(fixture):
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True)
    chamber = f"worldport:{MAP}:-38.5:811.8:-29.5"
    begin, finish = (fixture.directory / name for name in ("begin", "finish"))
    actions = [(wait(begin), "cmd:.debug castself 23136", wait(finish), "logout"), (wait(finish), "logout")]
    copy, logs, clients = open_party(fixture, characters, names, leader, client, nodes, True, actions,
                                     map_id=MAP, entrance=chamber)

    def actors(log):
        return {int(entry): int(guid) for entry, guid in re.findall(r"\[creature\] (\d+) guid (\d+):", log)
                if int(entry) in (KEEPER, JEEVEE)}

    begin.touch()
    wait_for("the original Keeper and J'eevee", lambda: all(len(actors(log)) == 2 for log in logs()), 22)
    original = actors(logs()[0])
    checkpoint = f"instance {copy} of map {MAP} saved an encounter checkpoint"
    host = wait_for("the ritual checkpoint", lambda: next((tag for tag in nodes if checkpoint in fixture.log(tag)), None), 10)
    assert all(f"[game object] {BELL}" not in log for log in logs()), "the crash must happen before the bell is placed"
    saved = fixture.query(f"SELECT data FROM instance WHERE id={copy}", characters)
    assert ":summons1:" in saved and ":steps1:" in saved
    offsets = list(map(len, logs()))
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        parts = [log[offset:] for log, offset in zip(logs(), offsets)]
        if all(f"[new world] map {MAP} " in log and actors(log) == original for log in parts):
            return parts

    wait_for("both original sockets to reload with the same ritual actors", recovered, 45)
    wait_for("J'eevee to place the bell after the crash",
             lambda: recovered() and all(f"[game object] {BELL}" in log for log in recovered()), 25)
    wave = r"\[creature\] (?:14482|14483) guid (\d+):"
    wait_for("the original ritual timeline to create one first wave",
             lambda: recovered() and all(len(set(re.findall(wave, log))) >= 10 and f"[game object] {CIRCLE}" in log
                                         for log in recovered()), 40)
    assert all(len(set(re.findall(wave, log))) == 10 for log in recovered())
    assert fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={copy}", characters) == "2"
    finish.touch()
    for i, client_process in enumerate(clients):
        if client_process.wait(timeout=26):
            raise RuntimeError(logs()[i][-3000:])
    print(f"PASS: killed {host}, retained both clients in Dire Maul {copy}, and resumed J'eevee and the first wave")


if __name__ == "__main__":
    run_test("dreadsteed-recovery", run)
