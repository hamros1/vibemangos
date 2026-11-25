#!/usr/bin/env python3
"""Hand a gateway player to a worker whose lease has lapsed, and finish the handoff once it holds again.

The loopback proxy drops the worker lease requests and replies between the coordinator and one
worker, so that worker's lease lapses while every link, the coordinator's majority and the term
stay as they were. A gateway client logs in at a position the worker owns: its arrival reaches the
worker during the lapse and must be held, then delivered once the lease replies flow again.
"""

import asyncio
import json
import os
import re
import subprocess
import sys
import time

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for
from cluster_proxy import ClusterProxy
from quorum import ELECTION


VOTERS = (1, 2, 3)
GATEWAY = 4
NODES = (*VOTERS, GATEWAY)
NAME = "Lapsewalker"
WORKER_LEASE = 59  # MessageType.quorumWorkerLease (source/dmangos/cluster/protocol.d)
METRICS = re.compile(r"cluster: node \d+( \(coordinator\))?, view .*; owns (\d+) region\(s\), lease (holds|LAPSED)")
# Places on both continents: the first one a worker (not the coordinator) simulates is used.
PLACES = ((0, -8901.6, -162.6, 82.0), (1, 1629.4, -4373.4, 31.3), (0, -4981.3, -881.5, 501.7),
          (1, -1277.4, 124.8, 131.3), (0, -8913.2, 554.6, 93.8))


def exercise(fixture, proxy, loop, world_ports, auth_port):
    def network(operation):
        return asyncio.run_coroutine_threadsafe(operation, loop).result(timeout=5)

    login = fixture.fresh_schema("login", "classicrealmd.sql")
    chars = fixture.fresh_schema("chars", "classiccharacters.sql")
    base = dict(fixture.base, bind_address="127.0.0.1", realm_id=1, idle_timeout=180,
                metrics_interval_seconds=1, login_database=login, character_database=chars)
    roster = [{"node_id": node, "address": f"{proxy.ADDRESS}:{proxy.ports[node]}"} for node in VOTERS]
    processes = {}
    for node in NODES:
        label = f"node{node}"
        config = dict(base, port=world_ports[node], write_log=f"{label}.writes")
        config["cluster"] = dict(name="lease-lapse-arrival", node_id=node, gateway=node == GATEWAY,
                                 listen_address=proxy.DESTINATION, advertise_address=proxy.ADDRESS,
                                 listen_port=proxy.ports[node], voters=roster, balance_interval_seconds=300)
        if node in VOTERS:
            config["cluster"]["vote_file"] = f"{label}.vote"
        processes[node] = fixture.start_world(label, config)

    def logs():
        output = {node: fixture.log(f"node{node}") for node in NODES}
        for node, process in processes.items():
            if process.poll() is not None:
                raise RuntimeError(f"node {node} exited:\n{output[node][-2500:]}")
        return output

    def elections(output):
        return {(int(term), int(node)) for log in output.values() for node, term in ELECTION.findall(log)}

    def lease(log):
        matches = METRICS.findall(log)
        return matches[-1][2] if matches else ""

    def ready():
        output = logs()
        elected = elections(output)
        if len(elected) == 1 and all(lease(output[node]) == "holds" for node in NODES):
            return next(iter(elected))

    term, leader = wait_for("the quorum and every node's lease", ready, 65)
    auth = fixture.directory / "auth.json"
    auth.write_text(json.dumps(dict(login_database=login, mysql_library=base["mysql_library"],
                                   bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
    account, password = "LEASELAPSE", "TESTLEASELAPSE"
    subprocess.run([AUTH, "-c", auth, "account", "create", account, password], cwd=fixture.directory,
                   check=True, timeout=15, stdout=subprocess.DEVNULL)
    fixture.grant_admins(login)
    fixture.start("auth", [AUTH, "-c", auth])
    wait_for("the login server", lambda: "listening on" in fixture.log("auth"), 15)

    def client(label, *actions):
        env = dict(os.environ, WORLD=f"127.0.0.1:{world_ports[GATEWAY]}", DMANGOS_TEST_WAITFILE_SECONDS="90")
        env.pop("REALM", None)
        return fixture.start(label, [sys.executable, "-u", REPO / "tools/testclient.py", str(auth_port),
                                     account, password, *actions], env=env)

    # The gateway refuses a creation until the coordinator has given it a block of character ids.
    for attempt in range(10):
        label = f"create{attempt}"
        if not client(label, "enum", f"create:{NAME}:1:1", "drop").wait(timeout=25) \
                and "(success)" in fixture.log(label):
            break
        time.sleep(1)
    else:
        raise RuntimeError(fixture.log(label))
    wait_for("the new character to be durable",
             lambda: fixture.query(f"SELECT guid FROM characters WHERE name='{NAME}'", chars), 10)

    def arrivals(node, place):
        _, x, y, _ = place
        return logs()[node].count(f"'{NAME}' arrived from another node (map {place[0]} at {x:.1f} {y:.1f})")

    # Find a place a worker other than the coordinator simulates.
    worker = place = None
    for attempt, candidate in enumerate(PLACES):
        map_id, x, y, z = candidate
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                      f"WHERE name='{NAME}'", chars)
        label, done = f"probe{attempt}", fixture.directory / f"probe{attempt}"
        probe = client(label, f"login:{NAME}", f"waitfile:{done}", "drop")
        owner = wait_for(f"the probe's worker at {candidate}",
                         lambda: next((node for node in VOTERS if arrivals(node, candidate)), None), 30)
        done.touch()
        if probe.wait(timeout=20):
            raise RuntimeError(fixture.log(label)[-2500:])
        wait_for("the probe to leave", lambda: f"'{NAME}' saved at" in logs()[owner], 15)
        time.sleep(1)  # its departure reaches the gateway
        if owner != leader:
            worker, place = owner, candidate
            break
    if worker is None:
        raise RuntimeError(f"coordinator {leader} simulates every place tried")
    print(f"node {leader} coordinates term {term}; node {worker} simulates {place}", flush=True)

    offsets = {node: len(log) for node, log in logs().items()}
    network(proxy.drop({(leader, worker): {WORKER_LEASE}, (worker, leader): {WORKER_LEASE}}))
    wait_for(f"node {worker}'s lease to lapse", lambda: lease(logs()[worker][offsets[worker]:]) == "LAPSED", 15)
    output = logs()
    assert elections(output) == {(term, leader)}, "the coordinator or term changed"
    assert all(lease(output[node][offsets[node]:]) in ("", "holds") for node in NODES if node != worker), \
        "a lease other than the worker's lapsed"

    gateway_offset = len(output[GATEWAY])
    worker_offset = len(output[worker])
    arrived = fixture.directory / "arrived"
    # Spoken at once: held (at the gateway during the hand-off, then on the worker during the lapse) and answered
    # once the worker holds its lease again.
    player = client("player", f"login:{NAME}", "say:during the lapse", f"waitfile:{arrived}", "say:after the lapse",
                    "logout")
    move = f"'{NAME}' moves to node {worker}"
    wait_for("the gateway to hand the player to the lapsed worker",
             lambda: move in logs()[GATEWAY][gateway_offset:], 20)
    time.sleep(3)
    held = logs()[worker][worker_offset:]
    assert lease(held) == "LAPSED", "the worker's lease came back while its replies were dropped"
    assert "arrived from another node" not in held, "the worker took the player in while its lease had lapsed"
    assert player.poll() is None, fixture.log("player")[-2500:]

    network(proxy.drop({}))
    released = re.compile(rf"cluster: node {worker} released (\d+) player message\(s\) held while its lease had lapsed")
    wait_for("the worker to deliver what it held", lambda: released.search(logs()[worker][worker_offset:]), 15)
    wait_for("the player to arrive on the worker", lambda: arrivals(worker, place) == 2, 15)
    # The release is logged once its messages are delivered, so after the arrival they include.
    tail = logs()[worker][worker_offset:]
    assert tail.index(f"'{NAME}' arrived from another node") < released.search(tail).start(), \
        "the player arrived without the held messages"
    arrived.touch()
    if player.wait(timeout=30):
        raise RuntimeError(fixture.log("player")[-2500:])
    assert "heard: 'during the lapse'" in fixture.log("player"), "what the client said during the lapse was lost"
    assert "heard: 'after the lapse'" in fixture.log("player"), "the client did not play on the worker"
    assert elections(logs()) == {(term, leader)}, "the coordinator or term changed"
    dropped = network(proxy.dropped_frames((leader, worker))) + network(proxy.dropped_frames((worker, leader)))
    print(f"PASS: node {worker} held the arrival through its lease lapse ({dropped} lease frames dropped) "
          f"and the client played on it in the same term {term}", flush=True)


def run(fixture):
    async def with_proxy():
        ports = available_ports(2 * len(NODES) + 1)
        peer_ports = dict(zip(NODES, ports))
        world_ports = dict(zip(NODES, ports[len(NODES):]))
        async with ClusterProxy(peer_ports) as proxy:
            await asyncio.to_thread(exercise, fixture, proxy, asyncio.get_running_loop(), world_ports, ports[-1])

    asyncio.run(with_proxy())


if __name__ == "__main__":
    run_test("lease-lapse-arrival", run)
