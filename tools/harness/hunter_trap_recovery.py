#!/usr/bin/env python3
"""Move a hunter to another worker and spring the original armed trap once."""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


TRAP, PLANT, SPRING = 2561, 1499, 3355


def run(fixture, clean):
    x, y, z = -9459.0, 97.0, 59.0
    world = fixture.world_with_writable_tables("creature")
    fixture.query(f"DELETE FROM creature WHERE map=0 AND position_x BETWEEN {x - 75} AND {x + 75} "
                  f"AND position_y BETWEEN {y - 75} AND {y + 75}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world,
                                                               leader_appearance=(3, 3))
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}",
                  characters)
    plant, spring, finish = (fixture.directory / flag for flag in ("plant", "spring", "finish"))
    player = client("player", 0, f"login:{names[0]}", "cmd:.cheat power", wait(plant), f"cmd:.debug castself {PLANT}",
                    wait(spring), "cmd:.npc spawn 38", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    def traps(output):
        return set(re.findall(rf"\[game object\] {TRAP} guid (\d+):", output))

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the hunter's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    plant.touch()
    original, = wait_for("the armed Freezing Trap", lambda: traps(log()), 12)
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    wait_for("the armed trap checkpoint", lambda: fixture.query(checkpoint, characters) == "1", 5)
    offset = len(log())
    nodes[host].send_signal(signal.SIGTERM if clean else signal.SIGKILL)
    assert nodes[host].wait(timeout=25) == (0 if clean else -signal.SIGKILL)
    if not clean:
        wait_for("the same hunter to reload", lambda: "[new world] map 0 " in log()[offset:], 30)
    wait_for("the original trap on the replacement worker", lambda: traps(log()[offset:]) == {original}, 20)
    spring.touch()
    wait_for("the original trap to freeze the hostile creature", lambda: f"received {SPRING}" in log()[offset:], 12)
    wait_for("the spent trap checkpoint to clear", lambda: fixture.query(checkpoint, characters) == "0", 6)
    finish.touch()
    assert player.wait(timeout=20) == 0
    output = fixture.log("player")
    assert output.count(f"[spell go] {SPRING} by {leader}") == 1
    assert traps(output) == {original}
    print(f"PASS: {'drained' if clean else 'killed'} {host}, kept the original Freezing Trap, and spent its charge once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true", help="drain the worker instead of killing it")
    args = parser.parse_args()
    run_test("hunter-trap-recovery", lambda fixture: run(fixture, args.clean))
