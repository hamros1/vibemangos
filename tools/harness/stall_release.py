#!/usr/bin/env python3
"""A worker whose own database stalls past database_stall_release_seconds gives up its players; nobody else does.

The cluster runs with a short limit. A second MariaDB session holds rows the workers write (each try then
times out after a second), in three steps with the same gateway player, on a worker other than the
coordinator:

1. Its character row, for less than the limit: the coordinator notices the worker's stall, nothing moves,
   and the save made meanwhile is written once the row is free.
2. Every row of dmangos_write_applied, which each node's writes and probes update, past the limit: every
   database stalls, the database itself being away, and nobody gives up.
3. Its character row again, past the limit: the coordinator fences the worker out, its lease lapses and
   what it queued is dropped, and the gateway restores the player on another worker from its last saved
   state. The change made during the stall is rolled back, the player speaks there and is answered, and the
   old worker joins again as a new incarnation.
"""

import re
import subprocess
import time

from cluster_fixture import run_test, wait_for
from departure_retry import hold_row
from dungeon_recovery import start_cluster, wait
from lease_lapse_arrival import PLACES
from quorum import ELECTION


LIMIT = 8  # database_stall_release_seconds
VOTERS = ("node1", "node2", "node3")
NOTICED = "cluster: node {}'s database has taken none of its writes for"
FENCED = re.compile(r"cluster: node (\d+)'s database has taken none of its writes for \d+ s \(over "
                    r"database_stall_release_seconds.* node \d+ \(incarnation (\d+)\) is fenced out")
SHARED = "no node's database has taken its writes all that time"
WRITING_AGAIN = "cluster: node {}'s database takes its writes again"
STALLED = "the database is unavailable: a queued"
ROLLED_BACK = "this node's lease lapsed while its database had taken none of its writes"
STARTED = re.compile(r"cluster: node (\d+) starts again as incarnation (\d+) \(was (\d+)\)")
RESTORED = "'{}' restored for its gateway from its last saved state"


def hold_ledger(fixture, characters):
    """A session that holds every row of dmangos_write_applied until `release` is called."""
    for _ in range(5):
        holder = subprocess.Popen([*fixture.mysql, "-NB", "--unbuffered", characters.rsplit(";", 1)[-1]],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  env=fixture.mysql_env, text=True)
        holder.stdin.write("BEGIN; SELECT stream FROM dmangos_write_applied FOR UPDATE; SELECT 'held';\n")
        holder.stdin.flush()
        lines = []
        while not lines or lines[-1] not in ("held", ""):
            lines.append(holder.stdout.readline().strip())
            if lines[-1].startswith("ERROR"):  # it waited for a write's lock too long: again
                break
        if lines[-1] == "held":
            break
        holder.kill()
        holder.wait()
    else:
        raise RuntimeError(f"could not hold dmangos_write_applied: {lines}")

    def release():
        holder.stdin.write("ROLLBACK;\n")
        holder.stdin.close()
        if holder.wait(timeout=10):
            raise RuntimeError("the session holding dmangos_write_applied failed")

    return release


def exercise(fixture):
    characters, names, guid, client, nodes, _ = start_cluster(
        fixture, new_party=True, cluster=dict(database_stall_release_seconds=LIMIT))
    leader = wait_for("the elected coordinator", lambda: next(
        (f"node{m.group(1)}" for tag in VOTERS for m in ELECTION.finditer(fixture.log(tag))), None), 30)

    def money():
        return int(fixture.query(f"SELECT money FROM characters WHERE guid={guid}", characters))

    # A place a worker other than the coordinator simulates.
    for attempt, (map_id, x, y, z) in enumerate(PLACES):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z},money=0 "
                      f"WHERE guid={guid}", characters)
        done = fixture.directory / f"probe{attempt}"
        probe = client(f"probe{attempt}", 0, f"login:{names[0]}", wait(done), "logout")
        arrival = f"'{names[0]}' arrived from another node (map {map_id} at {x:.1f} {y:.1f})"
        host = wait_for("the player's worker", lambda: next(
            (tag for tag in VOTERS if arrival in fixture.log(tag)), ""), 30)
        done.touch()
        if probe.wait(timeout=30):
            raise RuntimeError(fixture.log(f"probe{attempt}")[-2500:])
        time.sleep(2)  # its departure reaches the gateway
        if host != leader:
            break
    else:
        raise RuntimeError(f"coordinator {leader} simulates every place tried")
    node = int(host[4:])
    others = [tag for tag in VOTERS if tag != host]

    flags = {name: fixture.directory / name for name in ("short", "shared", "local", "resume")}
    player = client("player", 0, f"login:{names[0]}",
                    wait(flags["short"]), "cmd:.modify gold 111", "cmd:.server save",
                    wait(flags["shared"]), "say:after the short stall",
                    wait(flags["local"]), "say:after the shared stall", "cmd:.modify gold 222", "cmd:.server save",
                    wait(flags["resume"]), "say:after the release", "logout")
    wait_for("the player on its worker", lambda: fixture.log(host).count(arrival) == 2, 30)

    def tails(offsets):
        return {tag: fixture.log(tag)[offset:] for tag, offset in offsets.items()}

    def mark():
        return {tag: len(fixture.log(tag)) for tag in nodes}

    def alive():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(f"the player's client exited:\n{output[-2500:]}")
        return output

    # 1. The worker's own database stalls for less than the limit: noticed, and nothing more.
    offsets = mark()
    release = hold_row(fixture, characters, guid)
    try:
        flags["short"].touch()
        wait_for("the save to wait for the held row", lambda: STALLED in tails(offsets)[host], 10)
        wait_for("the coordinator to notice the worker's stall",
                 lambda: NOTICED.format(node) in tails(offsets)[leader], 10)
        assert money() == 0, "the save was written while the row was held"
    finally:
        release()
    wait_for("the save to be written once the row is free", lambda: money() == 111, 20)
    wait_for("the coordinator to see the worker write again",
             lambda: WRITING_AGAIN.format(node) in tails(offsets)[leader], 10)
    flags["shared"].touch()
    wait_for("the player to speak after the short stall", lambda: "heard: 'after the short stall'" in alive(), 15)
    tail = tails(offsets)
    assert not FENCED.search(tail[leader]), "a stall shorter than the limit fenced a worker out"
    assert "lease lapsed" not in tail[host] and STARTED.search(tail[host]) is None, "the worker gave up its lease"

    # 2. Every node's database stalls past the limit: nobody gives up.
    offsets = mark()
    release = hold_ledger(fixture, characters)
    try:
        wait_for("the coordinator to notice every simulating node's stall", lambda: all(
            NOTICED.format(tag[4:]) in tails(offsets)[leader] for tag in VOTERS), 15)
        wait_for("the stall to pass the limit", lambda: SHARED in tails(offsets)[leader], LIMIT + 15)
        time.sleep(2)
        tail = tails(offsets)
        assert not FENCED.search(tail[leader]), "a worker was fenced out while every database stalled"
    finally:
        release()
    wait_for("every node to write again", lambda: all(
        WRITING_AGAIN.format(tag[4:]) in tails(offsets)[leader] for tag in VOTERS), 30)
    tail = tails(offsets)
    assert not any("lease lapsed" in tail[tag] for tag in VOTERS), "a lease lapsed while every database stalled"

    # 3. The worker's own database stalls past the limit: it is fenced out, and its player plays on elsewhere.
    offsets = mark()
    release = hold_row(fixture, characters, guid)
    try:
        flags["local"].touch()
        wait_for("the player to speak after the shared stall", lambda: "heard: 'after the shared stall'" in alive(),
                 15)
        wait_for("the save to wait for the held row", lambda: STALLED in tails(offsets)[host], 10)
        fenced = wait_for("the coordinator to fence the worker out", lambda: FENCED.search(tails(offsets)[leader]),
                          LIMIT + 20)
        assert int(fenced.group(1)) == node, f"node {fenced.group(1)} was fenced out, not {host}"
        wait_for("the worker's lease to lapse, its queued writes dropped",
                 lambda: ROLLED_BACK in tails(offsets)[host], 15)
        assert money() == 111, "the save made during the stall was written"
    finally:
        release()
    restored = RESTORED.format(names[0])
    now_host = wait_for("the gateway to restore the player on another worker", lambda: next(
        (tag for tag in others if restored in tails(offsets)[tag]), ""), 30)
    flags["resume"].touch()
    if player.wait(timeout=40):
        raise RuntimeError(fixture.log("player")[-2500:])
    assert "heard: 'after the release'" in fixture.log("player"), "the player could not speak on its new worker"
    assert money() == 111, "the change made during the stall was not rolled back"
    started = wait_for("the old worker to join again as a new incarnation",
                       lambda: STARTED.search(tails(offsets)[host]), 30)
    assert int(started.group(1)) == node and started.group(3) == fenced.group(2)
    assert all(process.poll() is None for process in nodes.values()), "a node exited"
    print(f"PASS: {host}'s short stall released nothing, nor did a stall of every database past the limit; "
          f"its own stall past {LIMIT} s fenced it out, the player was restored on {now_host} as last saved "
          f"and spoke there, and {host} joined again as incarnation {started.group(2)}")


def run(fixture):
    # Each try of a held write waits a second for the lock (the nodes' sessions read this at connecting).
    previous = fixture.query("SELECT @@GLOBAL.innodb_lock_wait_timeout")
    fixture.query("SET GLOBAL innodb_lock_wait_timeout=1")
    try:
        exercise(fixture)
    finally:
        fixture.query(f"SET GLOBAL innodb_lock_wait_timeout={previous}")


if __name__ == "__main__":
    run_test("stall-release", run)
