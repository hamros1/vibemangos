#!/usr/bin/env python3
"""Kill the coordinator while a worker's region releases, and their objects, are on their way to it.

Single-standby mode. A gateway player plays at a place worker node 3 simulates, so its regions hold live
objects. The proxy holds node 3's frames to the coordinator for two seconds; node 3 is stopped cleanly
(SIGTERM: it drains, releasing every region with its objects), and the coordinator is killed as soon as
node 3 has sent its releases, which die with it in the proxy. The standby takes over and asks for the releases
again: each must come with its objects, and reach the region's next owner as a handover ("arrived with N
objects"), not load cold. The player plays on.
"""

import asyncio
import os
import re
import signal
import time

from cluster_fixture import available_ports, run_test, wait_for
from cluster_proxy import ClusterProxy
from lease_lapse_arrival import PLACES
from standby_cluster import COORDINATOR, FOURTH, NODES, STANDBY, TAKEOVER, WORKER, StandbyCluster


NAME = "Bundlewalker"
LOST = re.compile(r"cluster: regions gained \[[^\]]*\], lost \[([^\]]+)\]")
LEAVES = re.compile(r"migration: region (\d+) leaves for node \d+ with \d+ objects")


def region_ids(listed):
    """The ids in a `ClusterNode.regionIds` list: "3 (map 0, cells ...), 7 (map ...)" or "3, 7, ..."."""
    if "(map" in listed:
        return {int(m) for m in re.findall(r"(?:^|\), )(\d+) \(map", listed)}
    return {int(m) for m in re.findall(r"\d+", listed)}


def exercise(fixture, proxy, loop, world_ports, auth_port):
    def network(operation):
        return asyncio.run_coroutine_threadsafe(operation, loop).result(timeout=5)

    cluster = StandbyCluster(fixture, proxy, world_ports, auth_port, "standby-bundle", gateway=True,
                             account="STANDBYBUNDLE", password="TESTSTANDBYBUNDLE")
    cluster.create(NAME, FOURTH)
    alive = (COORDINATOR, STANDBY, WORKER, FOURTH)

    # A place node 3 simulates: the player keeps its cells loaded, so its regions go with live objects.
    held = player = None
    for attempt, (map_id, x, y, z) in enumerate(PLACES):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                      f"WHERE name='{NAME}'", cluster.chars)
        held = fixture.directory / f"held{attempt}"
        player = cluster.client(f"player{attempt}", FOURTH, f"login:{NAME}", f"waitfile:{held}",
                                "say:after the takeover", "logout")
        arrival = f"'{NAME}' arrived from another node (map {map_id} at {x:.1f} {y:.1f})"
        host = wait_for("the player's worker", lambda: next(
            (node for node in (COORDINATOR, STANDBY, WORKER) if arrival in cluster.log(node, alive)), None), 30)
        if host == WORKER:
            break
        held.touch()
        if player.wait(timeout=30):
            raise RuntimeError(fixture.log(f"player{attempt}")[-2500:])
        time.sleep(2)  # its departure reaches the gateway
    else:
        raise RuntimeError("node 3 simulates none of the places tried")
    label = f"player{attempt}"

    offsets = {node: len(cluster.log(node)) for node in NODES}
    network(proxy.delay({(WORKER, COORDINATOR): 2.0}))  # under the failure timeout: the link stays up
    os.kill(cluster.processes[WORKER].pid, signal.SIGTERM)
    released = wait_for("node 3 to release its regions",
                        lambda: LOST.search(cluster.log(WORKER)[offsets[WORKER]:]), 15)
    os.kill(cluster.processes[COORDINATOR].pid, signal.SIGKILL)  # the releases are still in the proxy
    # The world regions among them (services and dungeon maps go their own way): each left with its objects.
    regions = {int(m) for m in LEAVES.findall(cluster.log(WORKER)[offsets[WORKER]:])}
    assert regions and regions <= region_ids(released.group(1)), released.group(0)
    network(proxy.delay({}))

    alive = (STANDBY, FOURTH)
    wait_for("the standby to take over", lambda: TAKEOVER in cluster.log(STANDBY, alive)[offsets[STANDBY]:], 20)

    def handed_over():
        log = cluster.log(STANDBY, alive)[offsets[STANDBY]:]
        return all(re.search(rf"migration: region {region} arrived with \d+ objects", log) for region in regions)

    wait_for(f"regions {sorted(regions)} to reach their next owner with their objects", handed_over, 40)
    held.touch()
    if player.wait(timeout=40):
        raise RuntimeError(fixture.log(label)[-2500:])
    assert "heard: 'after the takeover'" in fixture.log(label), "the player could not play on"
    log = cluster.log(STANDBY)[offsets[STANDBY]:]
    objects = sum(int(re.search(rf"migration: region {region} arrived with (\d+) objects", log).group(1))
                  for region in regions)
    print(f"PASS: node 3's releases of regions {sorted(regions)} died with the coordinator; sent again to the "
          f"standby, they brought {objects} objects to their next owner, and the player played on", flush=True)


def run(fixture):
    async def with_proxy():
        ports = available_ports(2 * len(NODES) + 1)
        peer_ports = dict(zip(NODES, ports))
        world_ports = dict(zip(NODES, ports[len(NODES):]))
        async with ClusterProxy(peer_ports) as proxy:
            await asyncio.to_thread(exercise, fixture, proxy, asyncio.get_running_loop(), world_ports, ports[-1])

    asyncio.run(with_proxy())


if __name__ == "__main__":
    run_test("standby-bundle", run)
