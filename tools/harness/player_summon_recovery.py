#!/usr/bin/env python3
"""Check that a Shaman's totem and an engineering guardian survive a worker kill."""

import argparse
import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


TOTEM, TOTEM_CAST, PULSE = 5929, 8190, 8187
GUARDIAN, GUARDIAN_CAST = 8836, 13166


def run(fixture, scenario, retry_db):
    x, y, z = -9459.0, 97.0, 59.0
    world = fixture.world_with_writable_tables("creature")
    # Nearby hostiles can destroy a five-health totem before the harness reaches the worker kill.
    fixture.query(f"DELETE FROM creature WHERE map=0 AND position_x BETWEEN {x - 75} AND {x + 75} "
                  f"AND position_y BETWEEN {y - 75} AND {y + 75}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world,
                                                               leader_appearance=(2, 7))
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}",
                  characters)
    cast, remove, finish = (fixture.directory / flag for flag in ("cast", "remove", "finish"))
    expired = scenario == "expired-totem"
    totem_case = scenario in ("totem", "expired-totem")
    killed = scenario == "dead-guardian"
    entry, spell = (TOTEM, TOTEM_CAST) if totem_case else (GUARDIAN, GUARDIAN_CAST)
    actions = (f"cmd:.debug castself {spell}",)
    if killed:
        actions += (wait(remove), f"targetnpc:{GUARDIAN}", "cmd:.kill")
    player = client("player", 0, f"login:{names[0]}", "cmd:.cheat god", "cmd:.cheat power",
                    "cmd:.character additem 5176 1", wait(cast),
                    *actions, wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    def summons(output):
        return set(re.findall(rf"\[creature\] {entry} guid (\d+):", output))

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    cast.touch()
    original, = wait_for("the summon to appear", lambda: summons(log()), 12)
    seen = time.monotonic()

    def checkpoint_count():
        return fixture.query(f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}", characters)

    wait_for("the summon checkpoint", lambda: checkpoint_count() == "1", 8)
    if killed:
        remove.touch()
        wait_for("the guardian's death to clear its checkpoint", lambda: checkpoint_count() == "0", 8)
    pulse = f"[spell go] {PULSE} by {original}"
    if totem_case:
        wait_for("the original totem's first pulse", lambda: pulse in log(), 6)
    if expired:
        time.sleep(max(0, seen + 19 - time.monotonic()))
        assert checkpoint_count() == "1", "the worker must die before the totem expires"
    offset = len(log())
    if retry_db:
        fixture.query("RENAME TABLE dmangos_player_summons TO held_summons", characters)
    try:
        nodes[host].send_signal(signal.SIGKILL)
        assert nodes[host].wait(timeout=10) == -signal.SIGKILL
        if retry_db:
            failure = f"could not read character {leader}'s recovery checkpoint"
            wait_for("the replacement's failed summon read",
                     lambda: any(failure in fixture.log(tag) for tag in ("node1", "node2", "node3") if tag != host), 35)
            assert "[new world] map 0 " not in log()[offset:]
    finally:
        if retry_db:
            fixture.query("RENAME TABLE held_summons TO dmangos_player_summons", characters)

    def recovered():
        output = log()[offset:]
        return output.split("[new world] map 0 ", 1)[-1] if "[new world] map 0 " in output else ""

    wait_for("the original client to reload", lambda: "[appears] player" in recovered(), 35)
    if killed or expired:
        assert not summons(recovered()), "a retired summon reappeared"
    else:
        wait_for("the original summon", lambda: original in summons(recovered()), 12)
        assert summons(recovered()) == {original}, "a duplicate summon appeared"
    if totem_case and not expired:
        wait_for("a new pulse from the original totem", lambda: pulse in recovered(), 10)
        short_guid = ((entry & 0xFF) << 24) | int(original)
        gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
        wait_for("the restored totem to expire", lambda: gone.search(recovered()), 22)
        assert time.monotonic() - seen < 23, "the restored totem outlived its original 20-second duration"
        assert summons(recovered()) == {original}
    if totem_case or killed:
        wait_for("the retired summon checkpoint", lambda: checkpoint_count() == "0", 5)
    finish.touch()
    if player.wait(timeout=25):
        raise RuntimeError(fixture.log("player")[-3000:])
    if killed or expired:
        assert not summons(fixture.log("player")[offset:]), "a retired summon reappeared"
    wait_for("logout to retire the summon checkpoint", lambda: checkpoint_count() == "0", 5)
    print(f"PASS: {scenario} on the original socket after killing {host}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=("totem", "guardian", "dead-guardian", "expired-totem"), default="totem")
    parser.add_argument("--retry-db", action="store_true", help="fail the replacement's first read of summon state")
    args = parser.parse_args()
    run_test(f"player-summon-{args.scenario}", lambda fixture: run(fixture, args.scenario, args.retry_db))
