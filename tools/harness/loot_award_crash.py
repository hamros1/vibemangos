#!/usr/bin/env python3
"""Kill a worker after a remote loot award's claim and before its item is written: the item arrives once.

Two party members stand on either side of a region boundary, on two workers. The leader opens a chest and
the member wins the roll, so the award goes to the member's worker. A second MariaDB session locks the
member's inventory rows and the gap after them: the worker claims the award's token (a direct write), but
the item's write, which inserts the new inventory row in the same transaction, waits. (The member's other
saves, which add no item, go on: the worker takes the award only with its writes settled.) The worker is killed then. The claim must stay a
claim: the leader's worker must not take the item out of the loot as stored. The gateway restores the
member on another worker from its last save, the award is sent again, and the member stores it there under
its own claim: one copy of the prize, saved to the member.
"""

import itertools
import re
import signal
import subprocess
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from group_loot import CHEST, HERBALISM, PRIZE, world_with_chest
from named_objects import adjacent_boundary
from quorum import ELECTION


VOTERS = ("node1", "node2", "node3")
OWNS = re.compile(r"this node owns \[([^\]]*)\]")
REGION = re.compile(r"(\d+) \(map (\d+), cells x (-?\d+)\.\.(-?\d+), y (-?\d+)\.\.(-?\d+)\)")
CLAIMED = 255  # lootAwardClaimed (source/dmangos/world/database.d)
HUBS = {0: (-8949.95, -132.49), 1: (-618.0, -4252.0)}


def hold_inventory(fixture, characters, guid):
    """A session that locks `guid`'s inventory rows and the gap after them until `release` is called: no new
    inventory row of that character can be inserted meanwhile."""
    holder = subprocess.Popen([*fixture.mysql, "-NB", "--unbuffered", characters.rsplit(";", 1)[-1]],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=fixture.mysql_env, text=True)
    holder.stdin.write(f"BEGIN; SELECT COUNT(*) FROM (SELECT item FROM character_inventory WHERE guid={guid} "
                       f"FOR UPDATE) locked; SELECT 'held';\n")
    holder.stdin.flush()
    lines = [holder.stdout.readline().strip() for _ in range(2)]
    if lines[-1] != "held":
        holder.kill()
        raise RuntimeError(f"could not lock character {guid}'s inventory: {lines}")

    def release():
        holder.stdin.write("ROLLBACK;\n")
        holder.stdin.close()
        if holder.wait(timeout=10):
            raise RuntimeError("the session locking the inventory failed")

    return release


def layout(fixture):
    """Each worker's regions, {tag: {region: (map, (x0, x1), (y0, y1))}}, from its latest ownership line."""
    owned = {}
    for tag in VOTERS:
        lines = OWNS.findall(fixture.log(tag))
        owned[tag] = {int(region): (int(map_id), (int(x0), int(x1)), (int(y0), int(y1)))
                      for region, map_id, x0, x1, y0, y1 in REGION.findall(lines[-1])} if lines else {}
    return owned


def boundary(owned, leader):
    """A map, the leader's place and the member's, across a boundary of two workers; the member not on the
    coordinator (`leader`), which is not the one killed."""
    for map_id, hub in HUBS.items():
        for owner, member in itertools.permutations(VOTERS, 2):
            if member == leader:
                continue
            regions = {region: rect for tag in (owner, member) for region, (m, *rect) in owned[tag].items()
                       if m == map_id}
            worker = {region for region, (m, *_) in owned[member].items() if m == map_id}
            if not worker:
                continue
            try:
                owner_at, member_at = adjacent_boundary(regions, worker, hub)
            except RuntimeError:
                continue
            return map_id, owner, owner_at, member, member_at
    raise RuntimeError(f"no two workers share a boundary with the member off the coordinator: {owned}")


def run(fixture):
    world = world_with_chest(fixture)
    characters, names, leader_guid, client, nodes, _ = start_cluster(
        fixture, new_party=False, world=world, cluster={"balance_interval_seconds": 600})
    member_guid = int(fixture.query(f"SELECT guid FROM characters WHERE name='{names[1]}'", characters))
    coordinator = wait_for("the elected coordinator", lambda: next(
        (f"node{m.group(1)}" for tag in VOTERS for m in ELECTION.finditer(fixture.log(tag))), None), 30)
    owned = wait_for("the workers' regions", lambda: (lambda o: o if all(o.values()) else None)(layout(fixture)), 30)
    map_id, owner_tag, owner_at, member_tag, member_at = boundary(owned, coordinator)
    print(f"the leader on {owner_tag}, the member on {member_tag}, map {map_id}", flush=True)
    for guid, (x, y) in ((leader_guid, owner_at), (member_guid, member_at)):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={x},position_y={y},position_z=200 "
                      f"WHERE guid={guid}", characters)
    fixture.query(f"INSERT INTO character_spell (guid, spell) VALUES ({leader_guid}, {HERBALISM}); "
                  f"REPLACE INTO character_skills (guid, skill, value, max) VALUES ({leader_guid}, 182, 300, 300)",
                  characters)

    open_chest, done = fixture.directory / "open", fixture.directory / "done"
    member = client("member", 1, f"login:{names[1]}", "cmd:.cheat god", "rolloffer", "rollvote:1", wait(done),
                    "listen:2", "logout")
    leader = client("leader", 0, f"login:{names[0]}", "cmd:.cheat god", wait(open_chest),
                    f"cmd:.gobject spawn {CHEST} 1", "listen:1", f"castopen:{HERBALISM}:{CHEST}", "rolloffer",
                    "rollvote:2", wait(done), "listen:2", "logout")
    wait_for("both players on their workers", lambda: all(
        f"'{name}' arrived from another node" in fixture.log(tag)
        for name, tag in ((names[0], owner_tag), (names[1], member_tag))), 30)

    def award():
        return fixture.query(f"SELECT result FROM dmangos_loot_award WHERE player={member_guid}", characters)

    def prizes():
        return fixture.query(f"SELECT COUNT(*) FROM item_instance WHERE itemEntry={PRIZE} AND owner_guid={member_guid}",
                             characters)

    release = hold_inventory(fixture, characters, member_guid)
    try:
        open_chest.touch()
        wait_for("the member's worker to claim the award", lambda: award() == str(CLAIMED), 40)
        time.sleep(2)  # the item's write waits on the locked inventory
        assert prizes() == "0", "the item was written while the member's inventory was locked"
        nodes[member_tag].send_signal(signal.SIGKILL)
        assert nodes[member_tag].wait(timeout=10) == -signal.SIGKILL
    finally:
        release()
    assert award() == str(CLAIMED), "the claim was taken for a result when its worker died"
    assert prizes() == "0"

    restored = wait_for("the gateway to restore the member on another worker", lambda: next(
        (tag for tag in VOTERS if tag != member_tag and f"entered the world as '{names[1]}'" in fixture.log(tag)), ""), 40)
    wait_for("the award, sent again, to store the prize once", lambda: prizes() == "1" and award() == "0", 40)
    time.sleep(5)  # more rounds of the loot's poll: nothing more is stored
    assert prizes() == "1", "the prize was stored more than once"
    assert fixture.query(f"SELECT COUNT(*) FROM item_instance WHERE itemEntry={PRIZE} AND owner_guid={leader_guid}",
                         characters) == "0", "the prize went to the leader"
    done.touch()
    for label, process in (("member", member), ("leader", leader)):
        if process.wait(timeout=30):
            raise RuntimeError(f"{label} client failed:\n{fixture.log(label)[-2500:]}")
    assert all(process.poll() is None for tag, process in nodes.items() if tag != member_tag), "a node exited"
    print(f"PASS: {member_tag} died between the claim and the item's write; the member got one prize on {restored}")


def main(fixture):
    # The item's write waits a second for the locked inventory each try (the worker's sessions read this at connecting).
    previous = fixture.query("SELECT @@GLOBAL.innodb_lock_wait_timeout")
    fixture.query("SET GLOBAL innodb_lock_wait_timeout=1")
    try:
        run(fixture)
    finally:
        fixture.query(f"SET GLOBAL innodb_lock_wait_timeout={previous}")


if __name__ == "__main__":
    run_test("loot-award-crash", main)
