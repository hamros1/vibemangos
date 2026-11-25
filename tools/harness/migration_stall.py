#!/usr/bin/env python3
"""A move to another worker while the database stalls is refused, not dropped, and goes through once it is back.

A gateway player teleports to the other continent, which another worker simulates (the move a Hearthstone or
a summons to another worker's ground makes: `migrateTo`). A second MariaDB session holds the character's row,
so the move's own save cannot be written: the worker must answer the client with a transfer abort and keep
simulating the player, with its links and lease intact. Once the row is free, the same teleport moves the
player, and it plays on there.
"""

import time

from cluster_fixture import run_test, wait_for
from departure_retry import hold_row
from dungeon_recovery import start_cluster, wait
from lease_lapse_arrival import PLACES


VOTERS = ("node1", "node2", "node3")
ABORTED = "[transfer aborted] reason 2"


def arrived(fixture, name, offsets=None, besides=""):
    """A worker other than `besides` the player arrived on after `offsets` (log lengths), or ''. A move logs where
    the player left from: it is teleported on at the new worker."""
    arrival = f"'{name}' arrived from another node"
    return next((tag for tag in VOTERS if tag != besides and arrival in fixture.log(tag)[(offsets or {}).get(tag, 0):]),
                "")


def exercise(fixture):
    characters, names, guid, client, nodes, _ = start_cluster(
        fixture, new_party=True, cluster={"balance_interval_seconds": 600})
    name = names[0]
    eastern = [place for place in PLACES if place[0] == 0]
    kalimdor = [place for place in PLACES if place[0] == 1]

    # A start in the Eastern Kingdoms and a destination in Kalimdor that two different workers simulate.
    chosen = None
    for attempt, ((map_id, x, y, z), (to_map, tx, ty, tz)) in enumerate(
            (start, end) for start in eastern for end in kalimdor):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                      f"WHERE guid={guid}", characters)
        offsets = {tag: len(fixture.log(tag)) for tag in VOTERS}
        probe = client(f"probe{attempt}", 0, f"login:{name}", "cmd:.cheat god", "listen:2",
                       f"cmd:.go coords {to_map} {tx} {ty} {tz}", "listen:4", "logout")
        host = wait_for("the probe's worker", lambda: arrived(fixture, name, offsets), 30)
        offsets[host] = len(fixture.log(host))
        if probe.wait(timeout=40):
            raise RuntimeError(fixture.log(f"probe{attempt}")[-2500:])
        there = arrived(fixture, name, offsets, besides=host)
        time.sleep(2)  # its departure reaches the gateway
        if there and there != host:
            chosen = (map_id, x, y, z), (to_map, tx, ty, tz), host, there
            break
    if chosen is None:
        raise RuntimeError("one worker simulates every start and destination tried")
    (map_id, x, y, z), (to_map, tx, ty, tz), host, there = chosen
    print(f"moving from {host} (map {map_id}) to {there} (map {to_map})", flush=True)
    fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                  f"WHERE guid={guid}", characters)

    stalled, retry = fixture.directory / "stalled", fixture.directory / "retry"
    go = f"cmd:.go coords {to_map} {tx} {ty} {tz}"
    player = client("player", 0, f"login:{name}", "cmd:.cheat god", wait(stalled), go, "listen:4", wait(retry), go,
                    "listen:4", "say:after the stall", "logout")
    offsets = {tag: len(fixture.log(tag)) for tag in VOTERS}
    wait_for("the player on its first worker", lambda: arrived(fixture, name, offsets) == host, 30)
    offsets = {tag: len(fixture.log(tag)) for tag in VOTERS}

    release = hold_row(fixture, characters, guid)
    try:
        stalled.touch()
        wait_for("the client to be told the move cannot be made now", lambda: ABORTED in fixture.log("player"), 20)
        time.sleep(2)
        assert not arrived(fixture, name, offsets, besides=host), "the player moved while its save could not be written"
        assert player.poll() is None, "the client was dropped while the database stalled"
    finally:
        release()

    retry.touch()
    wait_for("the same teleport to move the player once the database is back",
             lambda: arrived(fixture, name, offsets, besides=host) == there, 30)
    if player.wait(timeout=30):
        raise RuntimeError(fixture.log("player")[-2500:])
    assert "heard: 'after the stall'" in fixture.log("player"), "the player could not play on after the move"
    assert all(process.poll() is None for process in nodes.values()), "a node exited"
    assert not any("closed: heartbeats stopped" in fixture.log(tag)[offsets[tag]:] for tag in VOTERS), \
        "a link timed out while the database stalled"
    assert "lease LAPSED" not in fixture.log(host)[offsets[host]:], "the worker's lease lapsed while the database stalled"
    print(f"PASS: the move from {host} to {there} was refused while the database stalled, then went through")


def run(fixture):
    # The move's save waits a second for the held row each try (the worker's sessions read this at connecting).
    previous = fixture.query("SELECT @@GLOBAL.innodb_lock_wait_timeout")
    fixture.query("SET GLOBAL innodb_lock_wait_timeout=1")
    try:
        exercise(fixture)
    finally:
        fixture.query(f"SET GLOBAL innodb_lock_wait_timeout={previous}")


if __name__ == "__main__":
    run_test("migration-stall", run)
