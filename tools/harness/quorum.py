#!/usr/bin/env python3
"""Kill the elected coordinator in a three-voter cluster with clients on a gateway.

Run after tools/harness/setup.sh and a release build. The test imports fresh login
and character schemas in the harness's MariaDB and reuses its world data. It leaves
logs and vote files under the harness directory and deletes the two test schemas.
"""

import re

from cluster_fixture import available_ports, run_test, wait_for


VOTERS = (1, 2, 3)
GATEWAY = 4
BOTS = 8
ELECTION = re.compile(r"cluster: node (\d+) elected coordinator for term (\d+)")
WORLD_PACKET = re.compile(r"^(\S+) < (SMSG_NEW_WORLD|SMSG_INITIAL_SPELLS) ", re.MULTILINE)


def run(fixture):
    base = dict(fixture.base, bind_address="127.0.0.1", realm_id=1, metrics_interval_seconds=1)
    base["login_database"] = fixture.fresh_schema("login", "classicrealmd.sql")
    base["character_database"] = fixture.fresh_schema("chars", "classiccharacters.sql")
    ports = available_ports(8)
    voters = [{"node_id": node, "address": f"127.0.0.1:{ports[node + 3]}"} for node in VOTERS]
    nodes = {}
    for node in (*VOTERS, GATEWAY):
        name = f"node{node}"
        config = dict(base, port=ports[node - 1], write_log=name + ".writes")
        config["cluster"] = {
            "name": "quorum-harness", "node_id": node, "gateway": node == GATEWAY,
            "listen_address": "127.0.0.1", "listen_port": ports[node + 3], "voters": voters,
        }
        if node in VOTERS:
            config["cluster"]["vote_file"] = f"{name}.vote"
        nodes[node] = fixture.start_world(name, config)

    def leader_after(term):
        elected = [
            (int(found_term), int(node))
            for node_id in VOTERS if nodes[node_id].poll() is None
            for node, found_term in ELECTION.findall(fixture.log(f"node{node_id}")) if int(found_term) > term
        ]
        return max(elected, default=None)

    term, leader = wait_for("an elected coordinator", lambda: leader_after(0), 45)
    gateway_log = f"node{GATEWAY}"
    wait_for("the gateway to follow the coordinator",
             lambda: f"node {leader} leads quorum term {term}" in fixture.log(gateway_log), 20)
    # An election is followed by issuing the first ownership grants and worker leases.
    wait_for("the gateway's lease and the initial regions",
             lambda: "lease holds" in fixture.log(gateway_log) and any(
                 re.search(r"owns [1-9]\d* region\(s\), lease holds", fixture.log(f"node{node}")) for node in VOTERS), 20)
    bots = fixture.start_clients("loadgen", base, ports[GATEWAY - 1], "--bots", str(BOTS), "--scenario", "crowd",
                                 "--duration", "45", "--warmup", "2", "--trace")
    fixture.wait_for_clients("loadgen", bots)
    trace_path = fixture.directory / "loadgen.log"
    trace_start = trace_path.stat().st_size

    # This is an ungraceful failure of a process created above, with every client still connected.
    nodes[leader].kill()
    nodes[leader].wait(timeout=10)
    next_term, successor = wait_for("a successor in a higher term", lambda: leader_after(term), 30)
    wait_for("the gateway to follow the successor",
             lambda: f"node {successor} leads quorum term {next_term}" in fixture.log(gateway_log), 15)
    print(f"coordinator {leader} in term {term} was replaced by {successor} in term {next_term}", flush=True)

    if bots.wait(timeout=50) or f"bots in the world at the end: {BOTS}; failed: 0" not in fixture.log("loadgen"):
        raise RuntimeError("a gateway client did not stay in the world after the election")
    with trace_path.open("rb") as trace:
        trace.seek(trace_start)
        transfers, recovered = set(), set()
        for account, opcode in WORLD_PACKET.findall(trace.read().decode(errors="replace")):
            if opcode == "SMSG_NEW_WORLD":
                transfers.add(account)
            elif account in transfers:
                recovered.add(account)
    if len(recovered) != BOTS:
        raise RuntimeError(f"only {len(recovered)}/{BOTS} gateway clients acknowledged their replacement world")
    if any(process.poll() is not None for node, process in nodes.items() if node != leader):
        raise RuntimeError("a surviving node exited during the test")
    print(f"PASS: all {BOTS} gateway clients stayed connected and recovered on the surviving nodes", flush=True)


if __name__ == "__main__":
    run_test("quorum", run)
