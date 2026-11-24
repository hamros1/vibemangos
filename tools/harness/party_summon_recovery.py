#!/usr/bin/env python3
"""Kill the recipient's worker with a party summon request open, then accept it once."""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture, retry_db):
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
    if retry_db:
        fixture.query("RENAME TABLE dmangos_party_summon_offer TO held_summon_offer", characters)
    try:
        nodes[host].send_signal(signal.SIGKILL)
        assert nodes[host].wait(timeout=10) == -signal.SIGKILL
        if retry_db:
            guid = fixture.query(f"SELECT guid FROM characters WHERE name='{names[1]}'", characters)
            failure = f"could not read character {guid}'s recovery checkpoint"
            wait_for("the replacement's failed summon offer read",
                     lambda: any(failure in fixture.log(tag) for tag in ("node1", "node2", "node3") if tag != host), 35)
            assert "[new world] map 0 " not in log("recipient", recipient)[offset:]
    finally:
        if retry_db:
            fixture.query("RENAME TABLE held_summon_offer TO dmangos_party_summon_offer", characters)

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


def open_ritual(fixture):
    spell, portal = 698, 36727
    world = fixture.world_with_writable_tables("spell_template")
    fixture.query(f"UPDATE spell_template SET DurationIndex=3 WHERE Id={spell}", world)
    characters, names, leader, client, nodes, _ = start_cluster(
        fixture, new_party=False, world=world, leader_appearance=(1, 9), extra_member=True)
    x, y, z = -8901.6, -162.6, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z}", characters)
    fixture.query(f"INSERT IGNORE INTO character_spell (guid,spell) VALUES ({leader},{spell})", characters)
    member = int(fixture.query(f"SELECT guid FROM characters WHERE name='{names[1]}'", characters))
    cast, join, complete, finish = (fixture.directory / flag for flag in ("cast", "join", "complete", "finish"))
    players = [
        client("owner", 0, f"login:{names[0]}", "cmd:.cheat power", "cmd:.character additem 6265 1", wait(cast),
               f"targetplayer:{member}", f"cast:{spell}", wait(finish), "logout"),
        client("member", 1, f"login:{names[1]}", wait(join), f"usego:{portal}", wait(finish), "logout"),
        client("helper", 2, f"login:{names[2]}", wait(complete), f"usego:{portal}", wait(finish), "logout"),
    ]
    labels = ("owner", "member", "helper")

    def logs():
        output = [fixture.log(label) for label in labels]
        for i, process in enumerate(players):
            if process.poll() is not None:
                raise RuntimeError(f"{labels[i]} exited:\n" + output[i][-2800:])
        return output

    host = wait_for("all three party members on the ritual's worker",
                    lambda: next((tag for tag in ("node1", "node2", "node3")
                        if all(f"'{name}' arrived from another node" in fixture.log(tag) for name in names)), ""), 30)
    cast.touch()
    channel = re.compile(rf"\[channel start\] {spell} for (\d+) ms")
    game_object = re.compile(rf"\[game object\] {portal} guid (\d+)")
    original = wait_for("the original summoning portal", lambda: game_object.search(logs()[0]), 12)[1]
    wait_for("the first helper to see the same portal", lambda: game_object.search(logs()[1]), 10)
    join.touch()
    wait_for("the first helper to join the original ritual", lambda: all(channel.search(log) for log in logs()[:2]), 10)
    request = f"[summon request] {leader} "
    assert not any(request in log for log in logs())
    offsets = [len(log) for log in logs()]
    nodes[host].kill()
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        return [log[offset:].partition("[new world] map 0 ")[2] for log, offset in zip(logs(), offsets)]

    wait_for("both original channels and the same portal on every original socket",
             lambda: all(channel.search(log) for log in recovered()[:2])
             and all(set(game_object.findall(log)) == {original} for log in recovered()), 38)
    complete.touch()
    wait_for("the third helper to finish the ritual and send one request",
             lambda: request in recovered()[1] and "[channel update] 0 ms" in recovered()[0], 15)
    finish.touch()
    for process in players:
        assert process.wait(timeout=20) == 0
    assert fixture.log("member").count(request) == 1
    assert fixture.log("owner").count(f"[spell go] {spell} by {leader}") == 1
    print(f"PASS: killed {host} after the first helper joined, restored the original portal, "
          "and produced one summon request after the third member joined")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    scenario = parser.add_mutually_exclusive_group()
    scenario.add_argument("--open-ritual", action="store_true", help="kill the owner after the first helper joins the portal")
    scenario.add_argument("--retry-db", action="store_true", help="fail the replacement's first read of the saved request")
    args = parser.parse_args()
    run_test("party-summon-recovery", open_ritual if args.open_ritual else lambda fixture: run(fixture, args.retry_db))
