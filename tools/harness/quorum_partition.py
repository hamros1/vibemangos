#!/usr/bin/env python3
"""Partition a live quorum coordinator and a worker, then heal the cluster."""

import asyncio
from itertools import combinations
import json
import os
import re
import subprocess
import sys

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for
from cluster_proxy import ClusterProxy
from quorum import ELECTION


VOTERS = (1, 2, 3, 4, 5)
GATEWAY = 6
NODES = (*VOTERS, GATEWAY)
NAME = "Partitioner"
REGIONS = re.compile(r"^(\S+).*cluster: regions gained \[([^\]]*)\], lost \[([^\]]*)\]; "
                     r"this node owns \[([^\]]*)\]", re.MULTILINE)
METRICS = re.compile(r"cluster: node \d+( \(coordinator\))?, view .*; owns (\d+) region\(s\), lease (holds|LAPSED)")


def region_ids(values):
    return set(map(int, values.split(","))) if values else set()


def check_reassignment(logs, offsets, original_regions):
    lost = {}
    gained = {}
    for node, log in logs.items():
        for timestamp, additions, removals, _ in REGIONS.findall(log[offsets[node]:]):
            if node in original_regions:
                for region in region_ids(removals) & original_regions[node]:
                    lost.setdefault(region, timestamp)
            else:
                for region in region_ids(additions):
                    gained[region] = min(gained.get(region, timestamp), timestamp)
    expected = set.union(*original_regions.values())
    assert lost.keys() >= expected, f"minority did not release regions {sorted(expected - lost.keys())}"
    if not gained.keys() >= expected:
        return False
    for region in expected:
        assert lost[region] <= gained[region], f"region {region} was granted before the minority released it"
    return True


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
        config["cluster"] = dict(name="quorum-partition", node_id=node, gateway=node == GATEWAY,
                                 listen_address=proxy.DESTINATION, advertise_address=proxy.ADDRESS,
                                 listen_port=proxy.ports[node], voters=roster, balance_interval_seconds=300)
        if node in VOTERS:
            config["cluster"]["vote_file"] = f"{label}.vote"
        processes[node] = fixture.start_world(label, config)

    def logs():
        output = {node: fixture.log(f"node{node}") for node in NODES}
        for node, process in processes.items():
            if process.poll() is not None:
                raise RuntimeError(f"node {node} exited during the partition test:\n{output[node][-2500:]}")
        return output

    def election(output):
        return max(((int(term), int(node)) for log in output.values()
                    for node, term in ELECTION.findall(log)), default=None)

    def follows(log, leader, term):
        return f"node {leader} leads quorum term {term}" in log

    def metrics(log):
        matches = METRICS.findall(log)
        return matches[-1] if matches else ("", "0", "")

    all_links = {frozenset(pair) for pair in combinations(NODES, 2)}

    def ready():
        output = logs()
        elected = election(output)
        if elected is None:
            return None
        term, leader = elected
        if (follows(output[GATEWAY], leader, term) and all(metrics(output[node])[2] == "holds" for node in NODES)
                and all(int(metrics(output[node])[1]) for node in VOTERS)
                and network(proxy.live_links()) >= all_links):
            return elected

    term, leader = wait_for("the initial quorum, region assignments and peer links", ready, 65)
    auth = fixture.directory / "auth.json"
    auth.write_text(json.dumps(dict(login_database=login, mysql_library=base["mysql_library"],
                                   bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
    account, password = "QUORUMPARTITION", "TESTQUORUM"
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

    creator = client("create", "enum", f"create:{NAME}:1:1", "drop")
    if creator.wait(timeout=25) or "(success)" not in fixture.log("create"):
        raise RuntimeError(fixture.log("create"))
    wait_for("the new character to be durable",
             lambda: fixture.query(f"SELECT guid FROM characters WHERE name='{NAME}'", chars), 10)
    x, y, z = -8901.6, -162.6, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z},money=0 "
                  f"WHERE name='{NAME}'", chars)

    def money():
        return int(fixture.query(f"SELECT money FROM characters WHERE name='{NAME}'", chars))

    checkpoint, change, resume, healed = (fixture.directory / flag for flag in ("checkpoint", "change", "resume", "healed"))
    player = client("player", f"login:{NAME}", f"waitfile:{checkpoint}", "cmd:.modify gold 1000", "cmd:.server save",
                    f"waitfile:{change}",
                    "cmd:.modify gold 100", "say:before partition", f"waitfile:{resume}",
                    "say:after takeover", "cmd:.modify gold 10", "cmd:.server save", f"waitfile:{healed}",
                    "say:after healing", "logout")

    def player_log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(f"gateway client exited early:\n{output[-2500:]}")
        return output

    arrival = f"'{NAME}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    owner = wait_for("the character's original worker", lambda: next(
        (node for node, log in logs().items() if arrival in log), None), 30)
    checkpoint.touch()
    wait_for("the original worker's durable gold checkpoint", lambda: money() == 1000, 12)
    change.touch()
    before_chat = "heard: 'before partition'"
    wait_for("the original worker to acknowledge unsaved progress", lambda: before_chat in player_log(), 12)
    assert "added 0 gold, 1 silver, 0 copper to your backpack" in player_log(), "the unsaved change was rejected"
    assert money() == 1000, "the change meant to be lost was already durable"

    # Two voters can remain connected to each other while three can still elect.
    worker = owner if owner != leader else next(node for node in VOTERS if node != leader)
    minority = {leader, worker}
    before = logs()
    offsets = {node: len(log) for node, log in before.items()}
    original_regions = {node: region_ids(REGIONS.findall(before[node])[-1][3]) for node in minority}
    assert all(original_regions.values()), "both minority nodes must own regions before the cut"
    client_offset = len(player_log())
    # Keep the nonvoting gateway visible to both sides. Losing its home early
    # could let the old simulation save and leave while its lease still holds.
    blocked = {pair for pair in all_links if GATEWAY not in pair and len(pair & minority) == 1}
    network(proxy.partition(blocked))
    assert network(proxy.live_links()) == all_links - blocked, "the cut must only close cross-partition voter links"
    print(f"partitioned coordinator {leader} and worker {worker}; player was on node {owner}", flush=True)

    def fenced():
        output = logs()
        tail = {node: output[node][offsets[node]:] for node in minority}
        return (f"lost its majority lease for term {term}" in tail[leader]
                and all(metrics(log) == ("", "0", "LAPSED") for log in tail.values())
                and f"'{NAME}' NOT saved" in tail[owner])

    wait_for("the minority to give up its leases, regions and unsaved character state", fenced, 25)
    assert frozenset(minority) in network(proxy.live_links()), "the isolated worker lost its link to the old coordinator"

    def takeover():
        output = logs()
        next_term, successor = election(output)
        if next_term <= term:
            return None
        assert successor not in minority, "a partitioned voter was elected"
        if follows(output[GATEWAY][offsets[GATEWAY]:], successor, next_term):
            return next_term, successor

    next_term, successor = wait_for("the gateway to follow the new majority coordinator", takeover, 30)
    wait_for("the majority to acquire the regions given up by the minority",
             lambda: check_reassignment(logs(), offsets, original_regions), 30)
    transfer = f"[new world] map 0 at {x:.1f} {y:.1f} {z:.1f}; answering"
    wait_for("the original client to acknowledge the checkpoint transfer", lambda: transfer in player_log()[client_offset:], 20)
    assert money() == 1000, "the former owner wrote its unsaved state after the lease expired"
    resume.touch()
    wait_for("the original client to play on the replacement", lambda: "heard: 'after takeover'" in player_log(), 15)
    wait_for("the replacement to save from the durable checkpoint", lambda: money() == 1010, 12)

    offsets = {node: len(log) for node, log in logs().items()}
    network(proxy.partition(set()))

    def rejoined():
        output = logs()
        assert election(output) == (next_term, successor), "the elected coordinator changed while healing"
        tails = [output[node][offsets[node]:] for node in minority]
        return (all(follows(log, successor, next_term) and metrics(log)[2] == "holds" for log in tails)
                and network(proxy.live_links()) == all_links)

    wait_for("both isolated voters to rejoin as members of the same term", rejoined, 30)
    assert money() == 1010, "the old owner overwrote the replacement's durable progress after rejoining"
    healed.touch()
    if player.wait(timeout=30):
        raise RuntimeError(fixture.log("player")[-2500:])
    recovered = fixture.log("player")[client_offset:]
    assert recovered.count(transfer) == 1, "the client did not receive exactly one recovery transfer"
    assert "heard: 'after healing'" in recovered, "the original client could not play after healing"
    assert money() == 1010, "the durable progress changed after healing and logging out"
    print(f"PASS: node {successor} took over in term {next_term}, the original client recovered, "
          "and both minority voters rejoined without overwriting its checkpoint", flush=True)


def run(fixture):
    async def with_proxy():
        ports = available_ports(2 * len(NODES) + 1)
        peer_ports = dict(zip(NODES, ports))
        world_ports = dict(zip(NODES, ports[len(NODES):]))
        async with ClusterProxy(peer_ports) as proxy:
            await asyncio.to_thread(exercise, fixture, proxy, asyncio.get_running_loop(), world_ports, ports[-1])

    asyncio.run(with_proxy())


if __name__ == "__main__":
    run_test("quorum-partition", run)
