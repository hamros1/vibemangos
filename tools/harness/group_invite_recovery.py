#!/usr/bin/env python3
"""Accept the original party invitation after killing its coordinator."""

import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


def run(fixture):
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True)
    member = fixture.query(f"SELECT guid FROM characters WHERE name='{names[1]}'", characters)
    invite, accept, finish = (fixture.directory / name for name in ("invite", "accept", "finish"))
    clients = [
        client("leader", 0, f"login:{names[0]}", wait(invite), f"invite:{names[1]}", wait(finish), "logout"),
        client("member", 1, f"login:{names[1]}", wait(accept), "accept", wait(finish), "logout"),
    ]

    def logs():
        output = [fixture.log(label) for label in ("leader", "member")]
        for i, process in enumerate(clients):
            if process.poll():
                raise RuntimeError(output[i][-2000:])
        return output

    wait_for("both clients routed to a worker", lambda: all(
        any(f"'{name}' arrived from another node" in fixture.log(f"node{node}") for node in (1, 2, 3))
        for name in names), 25)
    invite.touch()
    wait_for("the original party prompt", lambda: "[invited by]" in logs()[1], 15)
    assert fixture.query("SELECT COUNT(*) FROM dmangos_group_checkpoint WHERE realm=1 AND node=1", characters) == "1"
    assert fixture.query("SELECT COUNT(*) FROM groups", characters) == "0"

    nodes["node1"].send_signal(signal.SIGKILL)
    assert nodes["node1"].wait(timeout=10) == -signal.SIGKILL
    wait_for("a replacement coordinator with a lease", lambda: any(
        any(f"node {node} (coordinator)" in line and "lease holds" in line
            for line in fixture.log(f"node{node}").splitlines()) for node in (2, 3)), 35)
    accept.touch()
    wait_for("the original clients in the same new party", lambda: all("[group list] party" in log for log in logs()), 25)
    assert logs()[1].count("[invited by]") == 1
    assert fixture.query("SELECT leaderGuid FROM groups", characters) == str(leader)
    assert fixture.query("SELECT memberGuid FROM group_member ORDER BY memberGuid", characters).split() == [
        str(leader), member]
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=26):
            raise RuntimeError(fixture.log(("leader", "member")[i])[-3000:])
    print("PASS: the original party invite survived coordinator SIGKILL and formed one party on the same sockets")


if __name__ == "__main__":
    run_test("group-invite-recovery", run)
