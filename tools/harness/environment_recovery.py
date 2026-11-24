#!/usr/bin/env python3
"""Check that a worker crash preserves the gateway client's breath timer."""

import re
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture):
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True)
    x, y, surface, submerged = -9410.0, -2170.0, 56.2, 53.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={surface} "
                  f"WHERE guid={leader}", characters)
    dive, rise, finish = (fixture.directory / name for name in ("dive", "rise", "finish"))
    player = client("swimmer", 0, f"login:{names[0]}", wait(dive), f"move:{x + 0.5}:{y}:{submerged}",
                    wait(rise), f"move:{x}:{y}:{surface + 1}", wait(finish), "logout")

    def log():
        output = fixture.log("swimmer")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the swimmer's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    dive.touch()
    breath = re.compile(r"\[mirror timer\] 1: (\d+)/(\d+) ms, speed -1")
    initial = wait_for("the breath timer to start", lambda: breath.search(log()), 9)
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    wait_for("the saved breath timer", lambda: fixture.query(checkpoint, characters) == "1", 5)
    offset = len(log())
    started = time.monotonic()
    nodes[host].kill()
    assert nodes[host].wait(timeout=10) < 0

    def recovered():
        return log()[offset:].partition("[new world] map 0 ")[2]

    resumed = wait_for("the original client to reload with its active breath timer",
                       lambda: breath.search(recovered()), 37)
    left, maximum = map(int, resumed.groups())
    assert maximum == int(initial[2])
    assert 0 < left < int(initial[1]) - 1000
    assert abs((int(initial[1]) - left) / 1000 - (time.monotonic() - started)) < 3
    rise.touch()
    wait_for("surfacing to clear the saved hazard", lambda: "[mirror timer stopped] 1" in recovered()
             and fixture.query(checkpoint, characters) == "0", 10)
    finish.touch()
    assert player.wait(timeout=20) == 0
    print(f"PASS: killed {host}, preserved the remaining breath on the same socket, and cleared it after surfacing")


if __name__ == "__main__":
    run_test("environment-recovery", run)
