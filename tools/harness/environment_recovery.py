#!/usr/bin/env python3
"""Check that a worker crash preserves the gateway client's breath timer."""

import argparse
import re
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture, atomic=False):
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
    if atomic:
        return blocked_checkpoint(fixture, characters, leader, host, nodes, player, (x, y, surface),
                                  dive, rise, finish, log)
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


def blocked_checkpoint(fixture, characters, leader, host, nodes, player, surface, dive, rise, finish, log):
    x, y, z = surface
    schema = characters.rsplit(";", 1)[-1]
    position = f"SELECT ROUND(position_z*10) FROM characters WHERE guid={leader}"
    fixture.query("CREATE TRIGGER hold_swim_checkpoint BEFORE INSERT ON dmangos_player_summons "
                  "FOR EACH ROW SET @hold_swim = SLEEP(60)", characters)
    offset = len(log())
    dive.touch()
    blocker = wait_for("the worker blocked inside the effect write", lambda: fixture.query(
        f"SELECT ID FROM information_schema.PROCESSLIST WHERE DB='{schema}' AND STATE='User sleep'"), 12)
    assert blocker.isdecimal()
    assert fixture.query(position, characters) == str(round(z * 10)), "the new position leaked without the effect"
    nodes[host].kill()
    assert nodes[host].wait(timeout=10) < 0
    try:
        if fixture.query(f"SELECT ID FROM information_schema.PROCESSLIST WHERE ID={blocker}"):
            fixture.query(f"KILL CONNECTION {blocker}")
    finally:
        fixture.query("DROP TRIGGER hold_swim_checkpoint", characters)
    worldport = f"[new world] map 0 at {x:.1f} {y:.1f} {z:.1f};"
    wait_for("the original client to return to the committed position",
             lambda: worldport in log()[offset:] and "[appears] player" in log()[offset:], 35)
    rise.touch()
    finish.touch()
    assert player.wait(timeout=20) == 0
    assert "[mirror timer] 1" not in fixture.log("swimmer")[offset:]
    assert fixture.query(f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}", characters) == "0"
    print(f"PASS: killed {host} inside the recovery write, rolled back both the dive and its breath timer")


def interrupted_fall(fixture):
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True)
    x, y, start, falling, ground = -8901.6, -162.6, 112.0, 90.0, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={start} "
                  f"WHERE guid={leader}", characters)
    fall, land, finish = (fixture.directory / name for name in ("fall", "land", "finish"))
    landing = f"land:{x}:{y}:{ground}:650"
    player = client("faller", 0, f"login:{names[0]}", wait(fall), f"fall:{x}:{y}:{falling}:500",
                    wait(land), landing, landing, wait(finish), "logout")

    def log():
        output = fixture.log("faller")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the falling player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    fall.touch()
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    wait_for("the fall to be checkpointed", lambda: fixture.query(checkpoint, characters) == "1", 5)
    offset = len(log())
    nodes[host].kill()
    assert nodes[host].wait(timeout=10) < 0
    wait_for("the same client to reload at its last falling position",
             lambda: f"[new world] map 0 at {x:.1f} {y:.1f} {falling:.1f};" in log()[offset:]
             and "[appears] player" in log()[offset:], 35)
    land.touch()
    damage = re.compile(r"\[environment damage\] type 2: ([1-9]\d*)")
    wait_for("the original fall to do damage", lambda: damage.search(log()[offset:]), 8)
    wait_for("the landing to clear the fall checkpoint", lambda: fixture.query(checkpoint, characters) == "0", 6)
    assert fixture.query(f"SELECT ROUND(position_z) FROM characters WHERE guid={leader}", characters) == str(int(ground))
    finish.touch()
    assert player.wait(timeout=20) == 0
    assert len(damage.findall(fixture.log("faller")[offset:])) == 1
    print(f"PASS: killed {host} mid-fall and the original landing dealt damage once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument("--fall", action="store_true", help="kill the worker partway through a damaging fall")
    phase.add_argument("--atomic", action="store_true", help="kill the worker midway through saving a dive")
    args = parser.parse_args()
    run_test("environment-recovery", interrupted_fall if args.fall else lambda fixture: run(fixture, args.atomic))
