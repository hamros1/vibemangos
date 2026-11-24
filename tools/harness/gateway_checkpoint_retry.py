#!/usr/bin/env python3
"""Keep the original socket when a gateway cannot immediately read the player's checkpoint."""

import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture):
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True)
    x, y, z = -8901.6, -162.6, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}",
                  characters)
    resume = fixture.directory / "resume"
    message = "after checkpoint retry"
    player = client("player", 0, f"login:{names[0]}", wait(resume), f"say:{message}", "logout")

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    offset = len(fixture.log("player"))
    fixture.query("RENAME TABLE characters TO held_characters", characters)
    try:
        nodes[host].send_signal(signal.SIGKILL)
        assert nodes[host].wait(timeout=10) == -signal.SIGKILL
        failure = f"could not read character {leader}'s recovery position"
        wait_for("the failed first checkpoint read", lambda: failure in fixture.log("node4"), 35)
        assert nodes["node4"].poll() is None and player.poll() is None
    finally:
        fixture.query("RENAME TABLE held_characters TO characters", characters)

    worldport = f"[new world] map 0 at {x:.1f} {y:.1f} {z:.1f}; answering"
    wait_for("the same socket to reload at the saved position", lambda: worldport in fixture.log("player")[offset:], 20)
    resume.touch()
    assert player.wait(timeout=20) == 0
    assert f"heard: '{message}'" in fixture.log("player")[offset:]
    print(f"PASS: killed {host}, resumed after the failed checkpoint read, and sent chat on the original socket")


if __name__ == "__main__":
    run_test("gateway-checkpoint-retry", run)
