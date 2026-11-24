#!/usr/bin/env python3
"""Kill a worker during a Fireball cast and check that it resolves once."""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


SPELL, TARGET = 133, 38


def run(fixture, finished, projectile):
    world = fixture.world_with_writable_tables("spell_template", "creature")
    guid, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE map=0 "
                                  f"AND id={TARGET} ORDER BY guid LIMIT 1", world).split()
    x = float(x) + 4
    cast_options = "CastingTimeIndex=1,Speed=0.25" if projectile else "CastingTimeIndex=7"
    fixture.query(f"UPDATE spell_template SET {cast_options} WHERE Id={SPELL}; "
                  f"UPDATE creature SET MovementType=0,spawndist=0 WHERE guid={guid}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world,
                                                               leader_appearance=(1, 8))
    fixture.query(f"UPDATE characters SET map=0, position_x={x},position_y={y},position_z={z},orientation=3.14159265 "
                  f"WHERE guid={leader}", characters)
    cast, finish = (fixture.directory / flag for flag in ("cast", "finish"))
    player = client("player", 0, f"login:{names[0]}", "cmd:.cheat god", "cmd:.cheat power", wait(cast),
                    f"cast:{SPELL}:{TARGET}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {float(y):.1f})"
    host = wait_for("the caster's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    cast.touch()
    start = re.compile(rf"\[spell start\] {SPELL} by {leader}, (\d+) ms")
    initial = wait_for("the original in-flight cast", lambda: start.search(log()), 8)
    assert int(initial[1]) == (0 if projectile else 10000)
    spell_go = f"[spell go] {SPELL} by {leader}"
    if projectile:
        wait_for("the original launch", lambda: spell_go in log(), 4)
    else:
        assert spell_go not in log(), "the worker must die before the spell goes off"
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    wait_for("the cast checkpoint", lambda: fixture.query(checkpoint, characters) == "1", 4)
    hit = re.compile(rf"\[spell damage\] {SPELL}: \d+ to {guid}\b")
    if projectile:
        assert not hit.search(log()), "the worker must die before the missile lands"
    if finished:
        wait_for("the original hit before the worker kill", lambda: hit.search(log()), 16)
        assert fixture.query(checkpoint, characters) == "0"
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        output = log()[offset:]
        return output.split("[new world] map 0 ", 1)[-1] if "[new world] map 0 " in output else ""

    wait_for("the original client to reload", lambda: "[appears] player" in recovered(), 28)
    if finished:
        assert not start.search(recovered()), "the completed cast replayed"
    elif not projectile:
        restored = wait_for("the spell to resume on the existing socket", lambda: start.search(recovered()), 10)
        assert 0 <= int(restored[1]) < 10000
    if not finished:
        wait_for("the original Fireball to hit", lambda: hit.search(recovered()), 15)
    wait_for("the retired cast checkpoint", lambda: fixture.query(checkpoint, characters) == "0", 5)
    finish.touch()
    assert player.wait(timeout=20) == 0
    assert fixture.log("player").count(spell_go) == 1
    when = "with the missile in flight" if projectile else "after the cast" if finished else "during the cast"
    print(f"PASS: killed {host} {when}, "
          "resolved the original Fireball once, and kept the gateway socket")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument("--finished", action="store_true", help="kill the worker after the cast finishes")
    phase.add_argument("--projectile", action="store_true", help="kill the worker after launch but before impact")
    args = parser.parse_args()
    run_test("spell-cast-recovery", lambda fixture: run(fixture, args.finished, args.projectile))
