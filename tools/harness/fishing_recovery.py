#!/usr/bin/env python3
"""Kill an angler's worker and reel in the original cast on the same socket."""

import argparse
import ast
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture, canceled):
    world = fixture.world_with_writable_tables("spell_template")
    # Keep the normal fishing spell and lake. The fixture's character has no equipped pole.
    fixture.query("UPDATE spell_template SET EquippedItemClass=-1,EquippedItemSubClassMask=0 WHERE Id=7620", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    x, y, z = -9400, -2250, 58.2816
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z},orientation=0 "
                  f"WHERE guid={leader}", characters)
    cast, fish, finish = (fixture.directory / flag for flag in ("cast", "fish", "finish"))
    cancel = fixture.directory / "cancel"
    actions = (wait(cancel), "cancelchannel:7620") if canceled else (wait(fish), "fish")
    player = client("player", 0, f"login:{names[0]}", "cmd:.character learnskill 356 300 300", wait(cast),
                    "cmd:.debug castself 7620", *actions, wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    def bobbers(output):
        return set(re.findall(r"\[game object\] 35591 guid (\d+):", output))

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the angler's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    cast.touch()
    original, = wait_for("the fishing bobber", lambda: bobbers(log()), 12)
    wait_for("the active fishing channel", lambda: "[channel start] 7620" in log(), 5)
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    wait_for("the saved cast", lambda: fixture.query(checkpoint, characters) == "1", 6)
    if canceled:
        cancel.touch()
        wait_for("the canceled cast's checkpoint to clear", lambda: fixture.query(checkpoint, characters) == "0", 5)
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        output = log()[offset:]
        return output.split("[new world] map 0 ", 1)[-1] if "[new world] map 0 " in output else ""

    wait_for("the original client to reload", lambda: "[appears] player" in recovered(), 25)
    if not canceled:
        wait_for("the same bobber to reappear", lambda: bobbers(recovered()) == {original}, 10)
        duration = wait_for("the channel to resume", lambda: re.search(r"\[channel start\] 7620 for (\d+) ms",
                                                                       recovered()), 6)
        assert 0 < int(duration[1]) < 30000
        splash = re.compile(rf"\[game object animation\] 0x[\da-f]{{10}}{int(original):06x} slot 0")
        wait_for("the original bobber to splash", lambda: splash.search(recovered())
                 or re.search(rf"\[game object\] 35591 guid {original}:.*state 0", recovered()), 25)
        fish.touch()
        catch = wait_for("the catch on the original connection", lambda: re.search(r"\[fish loot\] (\[\(.+\)\])",
                                                                                    recovered()), 6)
        for _, item, count in ast.literal_eval(catch[1]):
            wait_for(f"the saved catch of item {item}", lambda: fixture.query(
                f"SELECT COALESCE(SUM(`count`),0) FROM item_instance WHERE owner_guid={leader} AND itemEntry={item}",
                characters) == str(count), 5)
        wait_for("the reeled-in cast's checkpoint to clear", lambda: fixture.query(checkpoint, characters) == "0", 5)
    assert bobbers(log()) == {original}
    finish.touch()
    assert player.wait(timeout=20) == 0
    if canceled:
        assert not bobbers(fixture.log("player")[offset:]), "the canceled bobber reappeared"
        print(f"PASS: killed {host}, kept the original socket, and the canceled bobber stayed gone")
    else:
        print(f"PASS: killed {host}, recovered the same fishing bobber, and landed the catch on the original socket")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canceled", action="store_true", help="cancel the cast before killing the worker")
    args = parser.parse_args()
    run_test("fishing-recovery", lambda fixture: run(fixture, args.canceled))
