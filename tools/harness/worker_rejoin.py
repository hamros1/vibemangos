#!/usr/bin/env python3
"""Stop a worker simulating a gateway player past its lease; once resumed it must rejoin as a new incarnation.

The coordinator drops the stopped worker and fences its process out: the gateway's player is restored
from its checkpoint on another worker. Resumed, the old process is refused, waits for its own lease to
lapse, and joins again as a new incarnation, while the player plays on where it was restored.
"""

import os
import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from lease_lapse_arrival import PLACES
from quorum import ELECTION


REFUSED = "the coordinator fenced this process (node {}, incarnation {}) out"
STARTED = re.compile(r"cluster: node (\d+) starts again as incarnation (\d+) \(was (\d+)\)")
INCARNATION = re.compile(r"cluster: node (\d+), incarnation (\d+),")
VOTERS = ("node1", "node2", "node3")


def run(fixture):
    characters, names, guid, client, nodes, _ = start_cluster(fixture, new_party=True)
    leader = wait_for("the elected coordinator", lambda: next(
        (f"node{m.group(1)}" for tag in VOTERS for m in ELECTION.finditer(fixture.log(tag))), None), 30)

    # A place a worker other than the coordinator simulates: stopping the coordinator is another case.
    for attempt, (map_id, x, y, z) in enumerate(PLACES):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                      f"WHERE guid={guid}", characters)
        resume = fixture.directory / f"resume{attempt}"
        player = client(f"player{attempt}", 0, f"login:{names[0]}", wait(resume), "say:after the rejoin", "logout")
        arrival = f"'{names[0]}' arrived from another node (map {map_id} at {x:.1f} {y:.1f})"
        host = wait_for("the player's worker", lambda: next(
            (tag for tag in VOTERS if arrival in fixture.log(tag)), ""), 30)
        if host != leader:
            break
        resume.touch()
        if player.wait(timeout=30):
            raise RuntimeError(fixture.log(f"player{attempt}")[-2500:])
        time.sleep(2)  # its departure reaches the gateway
    else:
        raise RuntimeError(f"coordinator {leader} simulates every place tried")

    node, first = map(int, INCARNATION.search(fixture.log(host)).groups())
    others = {tag: len(fixture.log(tag)) for tag in VOTERS if tag != host}
    offset = len(fixture.log(host))
    os.kill(nodes[host].pid, signal.SIGSTOP)
    time.sleep(9)  # past the failure timeout, the lease and its margin: the gateway restores the player elsewhere
    os.kill(nodes[host].pid, signal.SIGCONT)

    started = wait_for("the worker to start again as a new incarnation",
                       lambda: STARTED.search(fixture.log(host)[offset:]), 20)
    assert int(started.group(1)) == node and int(started.group(3)) == first and int(started.group(2)) > first
    tail = fixture.log(host)[offset:]
    assert REFUSED.format(node, first) in tail, "the worker started again without being refused"
    lapsed = "this node's lease lapsed: every session ends"
    assert lapsed in tail and tail.index(lapsed) < tail.index("starts again"), \
        "the worker started again before its lease lapsed"
    second = started.group(2)
    wait_for("the coordinator to link the new incarnation", lambda: f"linked to node {node} at" in
             fixture.log(leader)[others[leader]:] and f"(incarnation {second})" in fixture.log(leader)[others[leader]:],
             20)
    resume.touch()
    if player.wait(timeout=40):
        raise RuntimeError(fixture.log(f"player{attempt}")[-2500:])
    assert "heard: 'after the rejoin'" in fixture.log(f"player{attempt}"), "the player could not play on"
    assert all(process.poll() is None for process in nodes.values()), "a node exited"
    print(f"PASS: {host} was fenced out while stopped, then rejoined as incarnation {second}; the player played on")


if __name__ == "__main__":
    run_test("worker-rejoin", run)
