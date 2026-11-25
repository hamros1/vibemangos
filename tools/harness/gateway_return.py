#!/usr/bin/env python3
"""Chat through a gateway while the player changes workers; what reaches the old worker late comes back in order.

The client says a numbered line every 50 ms and, after the tenth, ports to ground of its map that another
worker simulates: within a second its worker hands it on there (the zone check). The loopback proxy delays
the frames from the gateway to that worker, so that the lines relayed there just before the hand-off reach
it after the player has left. It sends them back to the gateway (gatewayReturn), which must send them on
to the next worker ahead of those it held meanwhile, and only once the old worker has said it has sent back
all it had (gatewayFlushed). The client checks that every line is answered, in the order said. (A port to
another map would move the player first, and the lines said while its client loads the map go unheard.)
"""

import asyncio
import json
import os
import subprocess
import sys
import time

from cluster_fixture import AUTH, REPO, available_ports, run_test, wait_for
from cluster_proxy import ClusterProxy
from lease_lapse_arrival import PLACES
from quorum import ELECTION


VOTERS = (1, 2, 3)
GATEWAY = 4
NODES = (*VOTERS, GATEWAY)
NAME = "Returnwalker"
DELAY = 0.6  # seconds the gateway's frames to the player's worker take
LINES, INTERVAL, PORT_AFTER = 80, 50, 10  # the client's numbered says, ms apart; the port after this one
# More places, so that two on one map belong to different workers.
CANDIDATES = (*PLACES, (1, -956.7, -3754.7, 5.3), (0, 1586.5, 239.6, -52.1), (1, 9947.5, 2482.7, 1316.2),
              (0, -14297.2, 530.9, 8.8))
RETURNED = "came after its player left this node: back to its gateway"
GONE_ON = "packet(s) '{}' sent during its hand-off go on after"
LATE = "came back after the hand-off: sent on late"


def exercise(fixture, proxy, loop, world_ports, auth_port):
    def network(operation):
        return asyncio.run_coroutine_threadsafe(operation, loop).result(timeout=5)

    login = fixture.fresh_schema("login", "classicrealmd.sql")
    chars = fixture.fresh_schema("chars", "classiccharacters.sql")
    base = dict(fixture.base, bind_address="127.0.0.1", realm_id=1, idle_timeout=180, login_database=login,
                character_database=chars)
    roster = [{"node_id": node, "address": f"{proxy.ADDRESS}:{proxy.ports[node]}"} for node in VOTERS]
    processes = {}
    for node in NODES:
        label = f"node{node}"
        config = dict(base, port=world_ports[node], write_log=f"{label}.writes")
        config["cluster"] = dict(name="gateway-return", node_id=node, gateway=node == GATEWAY,
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

    wait_for("the quorum's coordinator", lambda: any(ELECTION.search(log) for log in logs().values()), 65)
    wait_for("the gateway's lease", lambda: "lease holds" in logs()[GATEWAY], 30)
    auth = fixture.directory / "auth.json"
    auth.write_text(json.dumps(dict(login_database=login, mysql_library=base["mysql_library"],
                                   bind_address="127.0.0.1", port=auth_port, realms_state_update_delay=1)))
    account, password = "GATEWAYRETURN", "TESTRETURNPATH"
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

    def place_character(place):
        map_id, x, y, z = place
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                      f"WHERE name='{NAME}'", chars)

    def arrived(node, place, offset=0):
        _, x, y, _ = place
        return f"'{NAME}' arrived from another node (map {place[0]} at {x:.1f} {y:.1f})" in logs()[node][offset:]

    # Two places on one map that different workers simulate.
    owners = {}
    for attempt, place in enumerate(CANDIDATES):
        offsets = {node: len(log) for node, log in logs().items()}
        place_character(place)
        label, done = f"probe{attempt}", fixture.directory / f"probe{attempt}"
        probe = client(label, f"login:{NAME}", f"waitfile:{done}", "drop")
        owner = wait_for(f"the probe's worker at {place}",
                         lambda: next((node for node in VOTERS if arrived(node, place, offsets[node])), None), 30)
        done.touch()
        if probe.wait(timeout=20):
            raise RuntimeError(fixture.log(label)[-2500:])
        wait_for("the probe to leave", lambda: f"'{NAME}' saved at" in logs()[owner][offsets[owner]:], 15)
        time.sleep(1)  # its departure reaches the gateway
        start = next((other for other, node in owners.items() if other[0] == place[0] and node != owner), None)
        if start is not None:
            old, target, new = owners[start], place, owner
            break
        owners[place] = owner
    else:
        raise RuntimeError(f"no two places on one map with different workers: {owners}")
    print(f"node {old} simulates {start}, node {new} {target}", flush=True)

    place_character(start)
    offsets = {node: len(log) for node, log in logs().items()}
    go = fixture.directory / "go"
    map_id, x, y, z = target
    player = client("player", f"login:{NAME}", f"waitfile:{go}",
                    f"chatter:{LINES}:{INTERVAL}:{PORT_AFTER}:{map_id}:{x}:{y}:{z}", "logout")
    wait_for("the player on its worker", lambda: arrived(old, start, offsets[old]), 30)
    time.sleep(11)  # a player moves to another worker's ground no sooner than ten seconds after its last move
    network(proxy.delay({(GATEWAY, old): DELAY}))
    go.touch()
    try:
        if player.wait(timeout=90):
            raise RuntimeError(fixture.log("player")[-3000:])
    finally:
        network(proxy.delay({}))
    output = logs()
    said = fixture.log("player")
    assert f"chatter: all {LINES} answered, in order" in said, said[-3000:]
    assert f"'{NAME}' arrived from another node" in output[new][offsets[new]:], "the player did not change workers"
    assert RETURNED in output[old][offsets[old]:], "no packet reached the old worker after the player left"
    held = [line for line in output[GATEWAY][offsets[GATEWAY]:].splitlines() if GONE_ON.format(account) in line]
    assert held and not held[-1].endswith(" 0 of them back from its old owner"), \
        f"the gateway did not send on what came back: {held}"
    assert LATE not in output[GATEWAY][offsets[GATEWAY]:], "a packet came back after the gateway had sent newer ones"
    print(f"PASS: {held[-1].split(': ', 1)[-1]}; every one of {LINES} lines answered in order, "
          f"from node {old} and then node {new}", flush=True)


def run(fixture):
    async def with_proxy():
        ports = available_ports(2 * len(NODES) + 1)
        peer_ports = dict(zip(NODES, ports))
        world_ports = dict(zip(NODES, ports[len(NODES):]))
        async with ClusterProxy(peer_ports) as proxy:
            await asyncio.to_thread(exercise, fixture, proxy, asyncio.get_running_loop(), world_ports, ports[-1])

    asyncio.run(with_proxy())


if __name__ == "__main__":
    run_test("gateway-return", run)
