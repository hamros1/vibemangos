#!/usr/bin/env python3
"""Kill the AQ40 worker during C'Thun's fight and resume it in the same raid copy on the same sockets.

    --phase transition  the worker dies after the Eye of C'Thun falls and before C'Thun rises: both original
                        clients come back to the same copy, C'Thun (the same creature) rises once, his two Flesh
                        Tentacles grow once, and no Eye or tentacle of the Eye's phase comes back.
    --phase stomach     the worker dies with the leader swallowed and one Flesh Tentacle slain: the leader's socket
                        comes back in the stomach, the acid resumes, the surviving Flesh Tentacle is the only one, and
                        its death weakens C'Thun; the leader climbs out and the member, kept outside the temple during
                        the fight, enters the same copy.
"""

import argparse
import re
import signal

from cluster_fixture import run_test, wait_for
from dungeon_recovery import open_party, start_cluster, wait


MAP = 531
EYE, CTHUN = 15589, 15727
CLAW, EYE_TENTACLE, GIANT_CLAW, GIANT_EYE, FLESH = 15725, 15726, 15728, 15334, 15802
CARAPACE, TRANSFORM, VULNERABLE, MOUTH_TENTACLE, DIGESTIVE_ACID = 26156, 26232, 26235, 26332, 26476
STOMACH = "-8563.6 2040.7 -97.0"
STOMACH_EXIT = "-8576.1 1985.8 100.2"
PLATFORM = 4033


def unit_guid(entry, spawn):
    return (0xF130 << 48) | (entry << 24) | spawn


def creatures(log, entry, living=True):
    """The spawn guids of `entry` the client was shown (alive, unless `living` is False)."""
    shown = {int(guid): int(health) for guid, health in
             re.findall(rf"\[creature\] {entry} guid (\d+): .*?health (\d+),", log)}
    dead = {int(guid) & 0xFFFFFF for guid in re.findall(r"\[changes\] (\d+): fields .*?health 0/", log)}
    return {guid for guid, health in shown.items() if not living or (health > 0 and guid not in dead)}


def aura(log, entry, spawn, spell):
    return f"[creature aura] {unit_guid(entry, spawn):#018x} received {spell}" in log


def prepare(fixture):
    world = fixture.base["world_database"]
    eye, ex, ey, ez = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE map={MAP} "
                                    f"AND id={EYE}", world).split()
    cthun = fixture.query(f"SELECT guid FROM creature WHERE map={MAP} AND id={CTHUN}", world)
    entrance = int(fixture.query(f"SELECT id FROM areatrigger_teleport WHERE target_map={MAP} LIMIT 1", world))
    characters, names, leader, client, nodes, trigger_position = start_cluster(fixture, new_party=False, raid=True)
    room = f"worldport:{MAP}:{float(ex) + 12}:{ey}:{ez}"
    return int(eye), int(cthun), entrance, room, characters, names, leader, client, nodes, trigger_position


def checkpoints(fixture, nodes, copy):
    line = f"instance {copy} of map {MAP} saved an encounter checkpoint"
    return {tag: fixture.log(tag).count(line) for tag in nodes}


def newer_checkpoint(fixture, nodes, copy, before):
    return next((tag for tag, count in checkpoints(fixture, nodes, copy).items() if count > before[tag]), None)


def kill_host(nodes, host):
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL


def same_copy(fixture, characters, copy, bound):
    assert fixture.query(f"SELECT id FROM instance WHERE map={MAP}", characters) == str(copy), "a second raid copy"
    assert fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={copy}", characters) == str(bound)


def no_native_fight_rows(fixture, characters, eye, cthun):
    assert fixture.query(f"SELECT COUNT(*) FROM dmangos_dungeon_fight WHERE spawn IN ({eye},{cthun})",
                         characters) == "0", "the encounter's own checkpoint owns the Eye and C'Thun"


def transition(fixture):
    eye, cthun, _, room, characters, names, leader, client, nodes, _ = prepare(fixture)
    engage, kill_eye, finish = (fixture.directory / name for name in ("engage", "kill-eye", "finish"))
    actions = [(wait(engage), f"attack:{EYE}", wait(kill_eye), f"killpack:{EYE}", wait(finish), "logout"),
               (wait(finish), "logout")]
    copy, logs, clients = open_party(fixture, characters, names, leader, client, nodes, False, actions,
                                     map_id=MAP, entrance=room)
    before = checkpoints(fixture, nodes, copy)
    engage.touch()
    host = wait_for("the checkpoint of C'Thun's fight under way", lambda: newer_checkpoint(fixture, nodes, copy, before), 15)
    wait_for("the Eye's first Claw Tentacle", lambda: creatures(logs()[0], CLAW), 12)
    before = checkpoints(fixture, nodes, copy)
    kill_eye.touch()
    eye_dead = f"[changes] {unit_guid(EYE, eye)}: fields"
    wait_for("the Eye slain", lambda: any(eye_dead in line and "health 0/" in line
                                          for line in logs()[0].splitlines()), 10)
    wait_for("the checkpoint of C'Thun's rise to come", lambda: newer_checkpoint(fixture, nodes, copy, before), 3)
    assert not any(aura(log, CTHUN, cthun, CARAPACE) for log in logs()), "the crash must come before C'Thun rises"
    assert ":summons1:" in fixture.query(f"SELECT data FROM instance WHERE id={copy}", characters)
    no_native_fight_rows(fixture, characters, eye, cthun)
    offsets = list(map(len, logs()))
    kill_host(nodes, host)

    def recovered():
        parts = [log[offset:] for log, offset in zip(logs(), offsets)]
        if all(f"[new world] map {MAP} " in log and f"[creature] {CTHUN} guid {cthun}:" in log for log in parts):
            return parts

    wait_for("both original sockets back in the copy with the same C'Thun", recovered, 45)
    wait_for("C'Thun to rise after the crash",
             lambda: recovered() and all(aura(log, CTHUN, cthun, CARAPACE) for log in recovered()), 12)
    wait_for("a Mouth Tentacle after his rise",
             lambda: recovered() and any(f"[spell go] {MOUTH_TENTACLE} by {cthun}" in log for log in recovered()), 15)
    after = recovered()
    for log in after:
        assert log.count(f"[spell go] {TRANSFORM} by {cthun}") <= 1, "he rose twice"
        assert not creatures(log, EYE), "the slain Eye came back"
        assert len(creatures(log, CTHUN)) == 1
        for entry in (CLAW, EYE_TENTACLE):
            assert not creatures(log, entry), f"a tentacle {entry} of the Eye's phase came back"
        assert len(creatures(log, FLESH, living=False)) <= 2, "more than two Flesh Tentacles grew"
    same_copy(fixture, characters, copy, 2)
    no_native_fight_rows(fixture, characters, eye, cthun)
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=30):
            raise RuntimeError(logs()[i][-4000:])
    print(f"PASS: killed {host} between the Eye's death and C'Thun's rise; both original clients saw the same "
          f"C'Thun rise once in raid copy {copy}, with no Eye or Eye-phase tentacle back")


def stomach(fixture):
    eye, cthun, entrance, room, characters, names, leader, client, nodes, trigger_position = prepare(fixture)
    outside = "worldport:1:" + ":".join(map(str, trigger_position(entrance, 1)))
    platform = f"worldport:{MAP}:" + ":".join(map(str, trigger_position(PLATFORM, MAP)))
    paths = (fixture.directory / name for name in ("engage", "kill-eye", "kill-flesh", "god", "kill-last", "climb",
                                                   "rejoin", "finish"))
    engage, kill_eye, kill_flesh, god, kill_last, climb, rejoin, finish = paths
    # The recovered session keeps its GM toggles (`dmangos_gm_session`); `on`, not a toggle, so that it stays immune.
    actions = [(wait(engage), f"attack:{EYE}", wait(kill_eye), f"killpack:{EYE}", wait(kill_flesh),
                f"killpack:one:{FLESH}", wait(god), "cmd:.cheat god on", wait(kill_last), f"killpack:{FLESH}", wait(climb),
                platform,
                f"trigger:{PLATFORM}", wait(finish), "logout"),
               (outside, wait(rejoin), f"trigger:{entrance}", wait(finish), "logout")]
    copy, logs, clients = open_party(fixture, characters, names, leader, client, nodes, False, actions,
                                     map_id=MAP, entrance=room)
    wait_for("the member outside the temple", lambda: "[new world] map 1 " in logs()[1].rsplit(f"map {MAP} ", 1)[-1], 15)
    engage.touch()
    wait_for("C'Thun's fight under way", lambda: newer_checkpoint(fixture, nodes, copy, {tag: 0 for tag in nodes}), 15)
    kill_eye.touch()
    wait_for("C'Thun to rise", lambda: aura(logs()[0], CTHUN, cthun, CARAPACE), 15)
    health = re.findall(rf"\[creature\] {CTHUN} guid {cthun}: .*?health (\d+),", logs()[0])[-1]
    wait_for("the leader swallowed", lambda: f"[teleport] to {STOMACH};" in logs()[0], 25)
    flesh = wait_for("both Flesh Tentacles in sight", lambda: (lambda seen: seen if len(seen) == 2 else None)(
        creatures(logs()[0], FLESH)), 10)
    before = checkpoints(fixture, nodes, copy)
    kill_flesh.touch()
    survivor = wait_for("one Flesh Tentacle slain", lambda: (lambda alive: alive if len(alive) == 1 else None)(
        creatures(logs()[0], FLESH)), 10)
    host = wait_for("the checkpoint of the slain Flesh Tentacle", lambda: newer_checkpoint(fixture, nodes, copy, before), 4)
    assert float(fixture.query(f"SELECT position_z FROM characters WHERE guid={leader}", characters)) < 0, \
        "the swallowed leader's position was not saved with the checkpoint"
    assert not aura(logs()[0], CTHUN, cthun, VULNERABLE)
    no_native_fight_rows(fixture, characters, eye, cthun)
    offset = len(logs()[0])
    kill_host(nodes, host)

    def recovered():
        log = logs()[0][offset:]
        if f"[new world] map {MAP} at {STOMACH};" in log:
            return log

    wait_for("the leader's socket back in C'Thun's stomach", recovered, 45)
    god.touch()
    wait_for("the Digestive Acid again", lambda: f"[periodic] {DIGESTIVE_ACID} " in recovered(), 8)
    after = recovered()
    assert creatures(after, FLESH) == survivor and creatures(after, FLESH, living=False) <= flesh, \
        f"Flesh Tentacles after the crash: {creatures(after, FLESH, living=False)}, before: {flesh}, alive {survivor}"
    assert not creatures(after, CTHUN, living=False) and not creatures(after, EYE, living=False), \
        "C'Thun (above, out of sight of the stomach) or an Eye seen from the stomach"
    kill_last.touch()
    wait_for("the second Flesh Tentacle slain", lambda: not creatures(recovered(), FLESH), 8)
    climb.touch()
    wait_for("the leader out of the stomach", lambda: f"[teleport] to {STOMACH_EXIT};" in recovered(), 10)
    # C'Thun is out of sight of the stomach: what he is is seen from the room, within his 45 s of weakness.
    wait_for("C'Thun weakened by the second Flesh Tentacle's death", lambda: aura(
        recovered().rsplit(f"[teleport] to {STOMACH_EXIT};", 1)[1], CTHUN, cthun, VULNERABLE), 10)
    room = recovered().rsplit(f"[teleport] to {STOMACH_EXIT};", 1)[1]
    assert creatures(room, CTHUN) == {cthun} and not creatures(room, EYE, living=False), "another C'Thun, or an Eye"
    assert re.findall(rf"\[creature\] {CTHUN} guid {cthun}: .*?health (\d+),", room)[-1] == health, \
        "C'Thun's health changed across the crash"
    wait_for("the way out saved", lambda: float(fixture.query(
        f"SELECT position_z FROM characters WHERE guid={leader}", characters)) > 0, 6)
    rejoin.touch()
    wait_for("the member entering the same raid copy",
             lambda: f"[new world] map {MAP} " in logs()[1].rsplit("[new world] map 1 ", 1)[-1], 20)
    same_copy(fixture, characters, copy, 2)
    no_native_fight_rows(fixture, characters, eye, cthun)
    finish.touch()
    for i, process in enumerate(clients):
        if process.wait(timeout=30):
            raise RuntimeError(logs()[i][-4000:])
    print(f"PASS: killed {host} with the leader in C'Thun's stomach; the original socket came back there in raid copy "
          f"{copy}, the acid resumed, the surviving Flesh Tentacle's death weakened him, and the member joined the copy")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=("transition", "stomach"), required=True)
    args = parser.parse_args()
    run_test(f"cthun-{args.phase}-recovery", transition if args.phase == "transition" else stomach)
