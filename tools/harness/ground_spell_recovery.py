#!/usr/bin/env python3
"""Kill the caster's worker after Consecration starts ticking."""

import argparse
import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


TARGET = 38  # Defias Thug


def run(fixture, channeled):
    spell = 10 if channeled else 26573  # Blizzard or Consecration
    world = fixture.world_with_writable_tables("spell_template", "creature")
    guid, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE map=0 "
                                  f"AND id={TARGET} ORDER BY guid LIMIT 1", world).split()
    x = float(x) + 1
    fixture.query(f"UPDATE spell_template SET DurationIndex=18 WHERE Id={spell}; "
                  f"UPDATE creature SET MovementType=0,spawndist=0 WHERE guid={guid}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}",
                  characters)
    cast, finish = (fixture.directory / flag for flag in ("cast", "finish"))
    player = client("player", 0, f"login:{names[0]}", "cmd:.cheat god", "cmd:.cheat power", wait(cast),
                    f"cmd:.debug castself {spell}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    def spots(output):
        return set(re.findall(rf"\[ground effect\] {spell} guid (\d+)", output))

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {float(y):.1f})"
    host = wait_for("the caster's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    cast.touch()
    original, = wait_for("the original ground spell", lambda: spots(log()), 12)
    seen = time.monotonic()
    tick = re.compile(rf"\[spell damage\] {spell}: \d+ to {guid}\b")
    wait_for("a tick on the Defias Thug", lambda: tick.search(log()), 6)
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    assert fixture.query(checkpoint, characters) == "1"
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        output = log()[offset:]
        return output.split("[new world] map 0 ", 1)[-1] if "[new world] map 0 " in output else ""

    wait_for("the original ground spell and a new tick on the same socket",
             lambda: spots(recovered()) == {original} and tick.search(recovered()), 28)
    if channeled:
        channel = re.search(rf"\[channel start\] {spell} for (\d+) ms", recovered())
        assert channel and 0 < int(channel[1]) < 20_000
    gone = re.compile(rf"\[out of range\] (?:\d+, )*{original}(?:,|$)", re.MULTILINE)
    wait_for("the original ground spell to expire", lambda: gone.search(recovered()), 22)
    assert time.monotonic() - seen < 23
    assert spots(log()) == {original}
    assert log().count(f"[spell go] {spell} by ") == 1
    wait_for("the expired effect's checkpoint to clear", lambda: fixture.query(checkpoint, characters) == "0", 6)
    finish.touch()
    assert player.wait(timeout=20) == 0
    print(f"PASS: killed {host}, restored {'Blizzard' if channeled else 'Consecration'} and kept its original expiry")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channeled", action="store_true", help="recover Blizzard's ground effect and active channel")
    args = parser.parse_args()
    run_test("ground-spell-recovery", lambda fixture: run(fixture, args.channeled))
