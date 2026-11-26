#!/usr/bin/env python3
"""Kill the coordinator while a worker's region releases, and their objects, are on their way to it.

Single-standby mode. A gateway player plays at a place worker node 3 simulates, so its regions hold live
objects. The proxy holds node 3's frames to the coordinator for two seconds; node 3 is stopped cleanly
(SIGTERM: it drains, releasing every region with its objects), and the coordinator is killed as soon as
node 3 has sent its releases, which die with it in the proxy. The standby takes over and asks for the releases
again: each must come with its objects, and reach the region's next owner as a handover ("arrived with N
objects"), not load cold. Node 3 keeps its lease through the takeover, and tells the standby it is draining, so
no region comes back to it: the player moves on, saved, to the node granted its ground, rather than being
restored from its last checkpoint. The player plays on.
"""

import asyncio
from collections import Counter
import hashlib
import os
import re
import signal
import struct
import time

from cluster_fixture import available_ports, run_test, wait_for
from cluster_proxy import ClusterProxy
from lease_lapse_arrival import PLACES
from standby_cluster import COORDINATOR, FOURTH, NODES, STANDBY, TAKEOVER, WORKER, StandbyCluster


NAME = "Bundlewalker"
LOST = re.compile(r"cluster: regions gained \[[^\]]*\], lost \[([^\]]+)\]")
LEAVES = re.compile(r"migration: region (\d+) leaves for node \d+ with (\d+) objects")
ARRIVES = re.compile(r"migration: region (\d+) arrived with (\d+) objects")
NPC = re.compile(r"\[creature\] (\d+) guid (\d+): level \d+, health [1-9]\d*, .*?npc flags [1-9]")
REGION_RELEASED = 6  # MessageType.regionReleased


def region_ids(listed):
    """The ids in a `ClusterNode.regionIds` list: "3 (map 0, cells ...), 7 (map ...)" or "3, 7, ..."."""
    if "(map" in listed:
        return {int(m) for m in re.findall(r"(?:^|\), )(\d+) \(map", listed)}
    return {int(m) for m in re.findall(r"\d+", listed)}


def exercise(fixture, proxy, loop, world_ports, auth_port, releases):
    def network(operation):
        return asyncio.run_coroutine_threadsafe(operation, loop).result(timeout=5)

    cluster = StandbyCluster(fixture, proxy, world_ports, auth_port, "standby-bundle", gateway=True,
                             account="STANDBYBUNDLE", password="TESTBUNDLE")
    cluster.create(NAME, FOURTH)
    alive = (COORDINATOR, STANDBY, WORKER, FOURTH)

    # A place node 3 simulates: the player keeps its cells loaded, so its regions go with live objects.
    held = player = None
    for attempt, (map_id, x, y, z) in enumerate(PLACES):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z={z} "
                      f"WHERE name='{NAME}'", cluster.chars)
        held = fixture.directory / f"held{attempt}"
        player = cluster.client(f"player{attempt}", FOURTH, f"login:{NAME}", f"waitfile:{held}",
                                "say:after the takeover", "visiblecreatures", "logout")
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

    npc = wait_for("a living NPC in sight", lambda: NPC.search(fixture.log(label)), 10).groups()
    client_offset = len(fixture.log(label))
    offsets = {node: len(cluster.log(node)) for node in NODES}

    async def hold_releases():
        for parts in releases.values():
            parts.clear()
        await proxy.delay({(WORKER, COORDINATOR): 2.0})

    network(hold_releases())
    os.kill(cluster.processes[WORKER].pid, signal.SIGTERM)
    released = wait_for("node 3 to release its regions",
                        lambda: LOST.search(cluster.log(WORKER)[offsets[WORKER]:]), 15)

    async def bundles(target):
        return dict(releases[target])

    lost = region_ids(released.group(1))

    def sent_all():
        parts = network(bundles(COORDINATOR))
        return parts if lost <= parts.keys() else None

    offered = wait_for("the outgoing region bundles in the proxy", sent_all, 5)
    os.kill(cluster.processes[COORDINATOR].pid, signal.SIGKILL)
    # The world regions among them (services and dungeon maps go their own way): each left with its objects.
    counts = {int(region): int(count) for region, count in LEAVES.findall(cluster.log(WORKER)[offsets[WORKER]:])}
    assert sum(counts.values()) > 0, "the departing regions held no objects"
    regions = set(counts)
    assert regions <= lost, released.group(0)
    network(proxy.delay({}))

    alive = (STANDBY, FOURTH)
    wait_for("the standby to take over", lambda: TAKEOVER in cluster.log(STANDBY, alive)[offsets[STANDBY]:], 20)

    def handed_over():
        log = cluster.log(STANDBY, alive)[offsets[STANDBY]:]
        arrivals = [(int(region), int(count)) for region, count in ARRIVES.findall(log) if int(region) in regions]
        if {region for region, _ in arrivals} != regions:
            return False
        assert Counter(arrivals) == Counter(counts.items()), (arrivals, counts)
        resent = network(bundles(STANDBY))
        assert all(resent.get(region) == offered[region] for region in regions), "a resent bundle changed"
        return True

    wait_for(f"regions {sorted(regions)} to reach their next owner with their objects", handed_over, 40)
    # Node 3 keeps its lease through the takeover and, draining, hands the player on, saved, once the standby has
    # granted its ground (after its first lease); it speaks once there. Restored from its checkpoint instead, it
    # would have lost what it did since, and the gateway what the client sent meanwhile.
    moved = f"'{NAME}' arrived from another node"
    wait_for("the player handed on to the standby", lambda: moved in cluster.log(STANDBY, alive)[offsets[STANDBY]:], 40)
    assert f"'{NAME}' NOT saved" not in cluster.log(WORKER)[offsets[WORKER]:], "node 3 lost its lease with the player"
    assert f"'{NAME}' restored for its gateway" not in cluster.log(STANDBY, alive)[offsets[STANDBY]:], \
        "the player was restored from its checkpoint, not handed on"
    held.touch()
    if player.wait(timeout=40):
        raise RuntimeError(fixture.log(label)[-2500:])
    assert "heard: 'after the takeover'" in fixture.log(label), "the player could not play on"
    entry, spawn = map(int, npc)
    guid = (0xF130 << 48) | (entry << 24) | spawn
    visible = re.search(r"^visible creature GUIDs:(.*)$", fixture.log(label), re.MULTILINE)
    assert visible and guid in map(int, visible[1].split()), f"NPC {npc} disappeared during handoff"
    shown = NPC.findall(fixture.log(label)[client_offset:]).count(npc)
    assert shown <= 1, f"NPC {npc} shown {shown} times after the drain began"
    objects = sum(counts.values())
    print(f"PASS: node 3's releases of regions {sorted(regions)} died with the coordinator; sent again to the "
          f"standby byte-for-byte, they restored {objects} objects, and the player moved on saved", flush=True)


def run(fixture):
    async def with_proxy():
        ports = available_ports(2 * len(NODES) + 1)
        peer_ports = dict(zip(NODES, ports))
        world_ports = dict(zip(NODES, ports[len(NODES):]))
        releases = {COORDINATOR: {}, STANDBY: {}}

        def observe(direction, kind, payload):
            source, target = direction
            if source == WORKER and target in releases and kind == REGION_RELEASED:
                region, = struct.unpack_from("<I", payload)
                releases[target][region] = hashlib.sha256(payload).digest()

        async with ClusterProxy(peer_ports, observe) as proxy:
            await asyncio.to_thread(exercise, fixture, proxy, asyncio.get_running_loop(), world_ports, ports[-1], releases)

    asyncio.run(with_proxy())


if __name__ == "__main__":
    run_test("standby-bundle", run)
