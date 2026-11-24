#!/usr/bin/env python3
"""Kill the recipient's worker with a party summon request open, then accept it once."""

import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture):
    world = fixture.world_with_writable_tables("spell_template")
    # Cast the real ritual's post-completion effect directly in this two-client test.
    fixture.query("UPDATE spell_template SET RangeIndex=4 WHERE Id=7720", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=False, world=world)
    x, y, z = -8901.6, -162.6, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}; "
                  f"UPDATE characters SET map=0,position_x={x - 20},position_y={y},position_z={z} "
                  f"WHERE guid<>{leader}", characters)
    cast, accept, finish = (fixture.directory / flag for flag in ("cast", "accept", "finish"))
    caller = client("caller", 0, f"login:{names[0]}", "cmd:.character learn 7720", wait(cast),
                    "castplayer:7720", wait(finish), "logout")
    recipient = client("recipient", 1, f"login:{names[1]}", wait(accept), f"summonaccept:{leader}",
                       f"summonaccept:{leader}", wait(finish), "logout")

    def log(tag, process):
        output = fixture.log(tag)
        if process.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    wait_for("the caller to see the recipient", lambda: "[appears] player" in log("caller", caller), 25)
    arrival = f"'{names[1]}' arrived from another node (map 0 at {x - 20:.1f} {y:.1f})"
    host = wait_for("the recipient's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 25)
    cast.touch()
    request = re.compile(rf"\[summon request\] {leader} in \d+, (\d+) ms left")
    wait_for("the original summon request", lambda: request.search(log("recipient", recipient)), 12)
    saved = fixture.query("SELECT sequence FROM dmangos_party_summon_offer WHERE state <> ''", characters)
    assert saved.isdigit()
    offset = len(log("recipient", recipient))
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        return log("recipient", recipient)[offset:]

    wait_for("the same client to reload after the worker kill", lambda: "[new world] map 0 " in recovered(), 35)
    restored = wait_for("the same summon request with its remaining time", lambda: request.search(recovered()), 12)
    assert 0 < int(restored[1]) < 120000
    accept.touch()
    arrival = f"[teleport] to {x:.1f} {y:.1f} {z:.1f};"
    wait_for("the recipient to teleport to the original destination", lambda: arrival in recovered(), 12)
    assert fixture.query(f"SELECT sequence FROM dmangos_party_summon_offer WHERE sequence={saved} AND state=''",
                         characters) == saved
    finish.touch()
    for process in (caller, recipient):
        assert process.wait(timeout=20) == 0
    assert fixture.log("recipient")[offset:].count(arrival) == 1
    print(f"PASS: killed {host}, kept the original summon request, and teleported once on the same socket")


if __name__ == "__main__":
    run_test("party-summon-recovery", run)
