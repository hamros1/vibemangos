#!/usr/bin/env python3
"""Report a gateway player's departure only once a stalled database has written its saves.

A second MariaDB session holds the character's row while the client disconnects, so the worker's
final save waits (each try times out after a second) and the departure must wait for it. Once the
row is free the save is written, the departure is reported, and the same account plays again.
"""

import subprocess
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


GOLD = 777
DEPARTURE_HELD = "cluster: account {} left before its saves were written; its departure waits for them"
DEPARTURE_REPORTED = "cluster: account {}'s departure reported now that its saves are written"
STALLED = "the database is unavailable: a queued"
RESUMED = "the database is back: writing again"


def hold_row(fixture, characters, guid):
    """A session that holds the character's row until `release` is called."""
    holder = subprocess.Popen([*fixture.mysql, "-NB", "--unbuffered", characters.rsplit(";", 1)[-1]],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=fixture.mysql_env, text=True)
    holder.stdin.write(f"BEGIN; SELECT guid FROM characters WHERE guid={guid} FOR UPDATE; SELECT 'held';\n")
    holder.stdin.flush()
    lines = [holder.stdout.readline().strip() for _ in range(2)]
    if lines != [str(guid), "held"]:
        holder.kill()
        raise RuntimeError(f"could not hold character {guid}'s row: {lines}")

    def release():
        holder.stdin.write("ROLLBACK;\n")
        holder.stdin.close()
        if holder.wait(timeout=10):
            raise RuntimeError("the session holding the character's row failed")

    return release


def exercise(fixture):
    # The default link and lease timeouts: the stalled database must not cost the worker its membership.
    characters, names, guid, client, nodes, _ = start_cluster(fixture, new_party=True)
    x, y, z = -8901.6, -162.6, 82.0
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z},money=0 "
                  f"WHERE guid={guid}", characters)
    account = int(fixture.query(f"SELECT account FROM characters WHERE guid={guid}", characters))

    def money():
        return int(fixture.query(f"SELECT money FROM characters WHERE guid={guid}", characters))

    change = fixture.directory / "change"
    player = client("player", 0, f"login:{names[0]}", wait(change), f"cmd:.modify gold {GOLD}", "drop")
    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    host = wait_for("the player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    offset = len(fixture.log(host))

    release = hold_row(fixture, characters, guid)
    try:
        change.touch()
        if player.wait(timeout=20):
            raise RuntimeError(fixture.log("player")[-2500:])
        assert "added 0 gold, 7 silver, 77 copper" in fixture.log("player"), "the unsaved change was rejected"
        held = DEPARTURE_HELD.format(account)
        wait_for("the worker to keep the departure while the save waits",
                 lambda: held in fixture.log(host)[offset:], 20)
        wait_for("the stalled save to be retried", lambda: STALLED in fixture.log(host)[offset:], 10)
        # Several more tries of the stalled save: the departure must not go out meanwhile.
        time.sleep(3)
        tail = fixture.log(host)[offset:]
        assert DEPARTURE_REPORTED.format(account) not in tail, "the departure was reported before the save"
        assert RESUMED not in tail, "the save was written while the row was held"
        assert money() == 0, "the save was written while the row was held"
    finally:
        release()

    reported = DEPARTURE_REPORTED.format(account)
    wait_for("the departure to be reported once the save is written", lambda: reported in fixture.log(host)[offset:], 20)
    tail = fixture.log(host)[offset:]
    assert tail.index(RESUMED) < tail.index(reported), "the departure went out before the save was written"
    assert tail.count(reported) == 1, "the departure was reported more than once"
    assert money() == GOLD, "the save made at the departure was lost"

    # The gateway drops a client's packets while it hands the player to a worker: speak once it arrived.
    arrived = fixture.directory / "arrived"
    again = client("again", 0, f"login:{names[0]}", wait(arrived), "say:after the departure", "logout")
    wait_for("the account to enter the world again on a worker", lambda: sum(
        fixture.log(tag).count(arrival) for tag in ("node1", "node2", "node3")) == 2, 30)
    arrived.touch()
    if again.wait(timeout=30):
        raise RuntimeError(fixture.log("again")[-2500:])
    assert "heard: 'after the departure'" in fixture.log("again"), "the account could not play again"
    assert all(process.poll() is None for process in nodes.values()), "a node exited"
    assert not any("closed: heartbeats stopped" in fixture.log(tag) for tag in ("node1", "node2", "node3", "node4")), \
        "a link timed out while the database stalled"
    assert "lease LAPSED" not in fixture.log(host)[offset:], "the worker's lease lapsed while the database stalled"
    print(f"PASS: {host} held account {account}'s departure until its stalled save was written, "
          "then the account logged in and played again")


def run(fixture):
    # The worker's save waits a second for the held row each try (its sessions read this at connecting).
    previous = fixture.query("SELECT @@GLOBAL.innodb_lock_wait_timeout")
    fixture.query("SET GLOBAL innodb_lock_wait_timeout=1")
    try:
        exercise(fixture)
    finally:
        fixture.query(f"SET GLOBAL innodb_lock_wait_timeout={previous}")


if __name__ == "__main__":
    run_test("departure-retry", run)
