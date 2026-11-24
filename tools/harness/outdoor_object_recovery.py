#!/usr/bin/env python3
"""Kill a worker after a spell places a temporary outdoor quest object."""

import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


SPELL, OBJECT = 18987, 177526  # Create Relic Bundle


def run(fixture):
    world = fixture.world_with_writable_tables("spell_template")
    # Use the quest spell's real object with a shorter lifetime and a cast at the fixture character.
    fixture.query(f"UPDATE spell_template SET DurationIndex=18,RequiresSpellFocus=0,EffectImplicitTargetA1=18 "
                  f"WHERE Id={SPELL}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    x, y, z = -8901.6, -162.6, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}",
                  characters)
    cast, finish = (fixture.directory / flag for flag in ("cast", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(cast), f"cmd:.debug castself {SPELL}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    def bundles(output):
        return set(re.findall(rf"\[game object\] {OBJECT} guid (\d+):", output))

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the region worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    cast.touch()
    original, = wait_for("the original relic bundle", lambda: bundles(log()), 12)
    seen = time.monotonic()
    checkpoint = f"FROM dmangos_quest_actor WHERE realm=1 AND player=0 AND (actor & 16777215)={original}"
    wait_for("the object checkpoint", lambda: fixture.query(f"SELECT COUNT(*) {checkpoint}", characters) == "1", 6)
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        output = log()[offset:]
        return output.split("[new world] map 0 ", 1)[-1] if "[new world] map 0 " in output else ""

    wait_for("the same socket to reload and see the same relic bundle", lambda: bundles(recovered()) == {original}, 30)
    short_guid = ((OBJECT & 0xFF) << 24) | int(original)
    gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
    wait_for("the original relic bundle to expire", lambda: gone.search(recovered()), 22)
    assert time.monotonic() - seen < 23, "the bundle outlived its original duration"
    assert bundles(log()) == {original}
    wait_for("the expired checkpoint to be deleted", lambda: fixture.query(f"SELECT COUNT(*) {checkpoint}",
                                                                              characters) == "0", 5)
    finish.touch()
    assert player.wait(timeout=20) == 0
    print(f"PASS: killed {host}, recovered the same relic bundle on the original socket, and expired it on time")


if __name__ == "__main__":
    run_test("outdoor-object-recovery", run)
