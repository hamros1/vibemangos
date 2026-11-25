#!/usr/bin/env python3
"""Kill the coordinator while an account plays on one worker and logs in on another: never in the world twice.

Single-standby mode. The account's character plays on worker node 3, its client connected there. The
coordinator is killed, and at once the same account logs in on node 4. The standby takes over knowing no
session; node 3 claims its session again as already granted, node 4's login is a new one and waits one lease.
The new login evicts node 3's session, which saves and leaves, and only then enters the world on node 4.
The harness watches both logs every 50 ms and fails if node 4 lets the character in while it is still in the
world on node 3.
"""

import asyncio
import os
import signal
import time

from cluster_fixture import available_ports, run_test, wait_for
from cluster_proxy import ClusterProxy
from standby_cluster import COORDINATOR, FOURTH, NODES, STANDBY, TAKEOVER, WORKER, StandbyCluster


NAME = "Standwalker"


def exercise(fixture, proxy, world_ports, auth_port):
    cluster = StandbyCluster(fixture, proxy, world_ports, auth_port, "standby-login", gateway=False,
                             account="STANDBYLOGIN", password="TESTSTANDBYLOGIN")
    cluster.create(NAME, WORKER)
    entered = f"entered the world as '{NAME}'"
    left = f"'{NAME}' saved at"
    alive = (STANDBY, WORKER, FOURTH)

    held = fixture.directory / "held"
    first = cluster.client("first", WORKER, f"login:{NAME}", f"waitfile:{held}", "logout")
    wait_for("the character in the world on node 3", lambda: entered in cluster.log(WORKER, alive), 30)
    offsets = {node: len(cluster.log(node)) for node in NODES}

    os.kill(cluster.processes[COORDINATOR].pid, signal.SIGKILL)
    second = cluster.client("second", FOURTH, f"login:{NAME}", "say:after the takeover", "logout")

    left_at = entered_at = None
    deadline = time.monotonic() + 60
    while entered_at is None and time.monotonic() < deadline:
        now = time.monotonic()
        if left_at is None and left in cluster.log(WORKER, alive)[offsets[WORKER]:]:
            left_at = now
        if entered in cluster.log(FOURTH, alive)[offsets[FOURTH]:]:
            entered_at = now
            assert left_at is not None, "node 4 let the character in while it was still in the world on node 3"
        time.sleep(0.05)
    if entered_at is None:
        raise RuntimeError("the second login never entered the world:\n" + fixture.log("second")[-2500:])
    held.touch()
    if second.wait(timeout=40):
        raise RuntimeError(fixture.log("second")[-2500:])
    first.wait(timeout=30)
    standby = cluster.log(STANDBY)[offsets[STANDBY]:]
    assert TAKEOVER in standby, "the standby did not take over"
    assert "logged in again; its session on node 3 is ended" in standby, "node 3's session was never evicted"
    assert "heard: 'after the takeover'" in fixture.log("second"), "the second login could not play"
    print(f"PASS: after the takeover the second login entered the world {entered_at - left_at:.2f} s after the "
          "first had left it, never alongside it", flush=True)


def run(fixture):
    async def with_proxy():
        ports = available_ports(2 * len(NODES) + 1)
        peer_ports = dict(zip(NODES, ports))
        world_ports = dict(zip(NODES, ports[len(NODES):]))
        async with ClusterProxy(peer_ports) as proxy:
            await asyncio.to_thread(exercise, fixture, proxy, world_ports, ports[-1])

    asyncio.run(with_proxy())


if __name__ == "__main__":
    run_test("standby-login", run)
