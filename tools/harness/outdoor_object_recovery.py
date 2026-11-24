#!/usr/bin/env python3
"""Recover a temporary quest object across worker crashes and an idle grid."""

import argparse
import re
import signal
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from group_loot import round_positions


SPELL, OBJECT = 18987, 177526  # Create Relic Bundle
FOCUS_SPELL, FOCUS, DURATION = 1459, 987654, 36


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


def run_creation(fixture, phase):
    world = fixture.world_with_writable_tables("spell_template", "gameobject_template")
    fixture.query(f"UPDATE spell_template SET DurationIndex=325,CastingTimeIndex=1,RequiresSpellFocus=0 "
                  f"WHERE Id={SPELL}; UPDATE spell_template SET RequiresSpellFocus={FOCUS},ManaCost=0 "
                  f"WHERE Id={FOCUS_SPELL}; UPDATE gameobject_template SET data0={FOCUS} WHERE entry={OBJECT}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)

    def ownership():
        result = {}
        for node in (1, 2, 3):
            lists = re.findall(r"this node owns \[([^]]+)\]", fixture.log(f"node{node}"))
            if not lists:
                return None
            result[node] = set(map(int, re.findall(r"\d+", lists[-1])))
        return result

    owners = wait_for("the workers to own regions", ownership, 25)
    map_id, (source, sx, sy), (destination, dx, dy), _ = round_positions(fixture.log("node1"), owners)
    caster_worker, object_worker = f"node{source}", f"node{destination}"
    z = 200
    fixture.query(f"UPDATE characters SET map={map_id},position_x={sx},position_y={sy},position_z={z} WHERE guid={leader}; "
                  f"UPDATE characters SET map={map_id},position_x={dx},position_y={dy},position_z={z} WHERE guid<>{leader}; "
                  f"INSERT INTO character_spell (guid,spell) VALUES ({leader},{SPELL}); "
                  f"INSERT INTO character_spell (guid,spell) SELECT guid,{FOCUS_SPELL} FROM characters WHERE guid<>{leader}",
                  characters)
    if phase == "during":
        fixture.query("CREATE TRIGGER hold_object BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_object = IF((NEW.actor >> 24) & 16777215 = {OBJECT}, SLEEP(60), 0)", characters)
    if phase == "after":
        fixture.query("CREATE TRIGGER hold_object BEFORE DELETE ON dmangos_outdoor_summon FOR EACH ROW "
                      "SET @hold_object = IF(OLD.kind=1 AND OLD.actor <> 0, SLEEP(60), 0)", characters)
    if phase == "before-enqueue":
        fixture.query("CREATE TRIGGER hold_object BEFORE INSERT ON dmangos_outdoor_summon FOR EACH ROW "
                      "SET @hold_object = IF(NEW.kind=1, SLEEP(60), 0)", characters)

    cast, retry, probe, use, finish = (fixture.directory / name for name in ("cast", "retry", "probe", "use", "finish"))
    create = f"castat:{SPELL}:{dx}:{dy}:{z}"
    repeat = (wait(retry), create) if phase == "before-enqueue" else ()
    player = client("player", 0, f"login:{names[0]}", wait(cast), create, *repeat, wait(finish), "logout")
    observer = client("observer", 1, f"login:{names[1]}", wait(probe), f"cast:{FOCUS_SPELL}", wait(use), f"cast:{FOCUS_SPELL}",
                      wait(finish), "logout")

    def log(label, process):
        output = fixture.log(label)
        if process.poll() is not None:
            raise RuntimeError(output[-3500:])
        return output

    def player_log():
        return log("player", player)

    def observer_log():
        return log("observer", observer)

    for tag, name, x, y in ((caster_worker, names[0], sx, sy), (object_worker, names[1], dx, dy)):
        wait_for(f"{name} to reach {tag}", lambda: f"'{name}' arrived from another node (map {map_id} at "
                 f"{x:.1f} {y:.1f})" in fixture.log(tag), 25)
    probe.touch()
    wait_for("the focus spell to fail before the bundle exists",
             lambda: f"[cast result] {FOCUS_SPELL}: failed" in observer_log(), 10)

    queue = "FROM dmangos_outdoor_summon WHERE realm=1 AND kind=1"
    actors = f"FROM dmangos_quest_actor WHERE realm=1 AND player=0 AND (actor >> 24) & 16777215 = {OBJECT}"

    def drop(tag):
        nodes[tag].send_signal(signal.SIGKILL)
        assert nodes[tag].wait(timeout=10) == -signal.SIGKILL

    original = None
    if phase == "sender":
        nodes[object_worker].send_signal(signal.SIGSTOP)
        try:
            started = time.monotonic()
            cast.touch()
            wait_for("the object request to commit before delivery", lambda: fixture.query(
                f"SELECT actor {queue}", characters) == "0", 6)
            assert not fixture.query(f"SELECT actor {actors}", characters)
            recovered_log, recovery_offset = player_log, len(player_log())
            observer_offset = len(observer_log())
            drop(caster_worker)
        finally:
            nodes[object_worker].send_signal(signal.SIGCONT)
    else:
        started = time.monotonic()
        cast.touch()
        schema = characters.rsplit(";", 1)[-1]
        connection = wait_for("the destination to reach the object save boundary", lambda: fixture.query(
            "SELECT ID FROM information_schema.PROCESSLIST "
            f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_object =%'"), 14)
        assert connection.isdecimal(), connection
        if phase == "after":
            actor = int(fixture.query(f"SELECT actor {actors}", characters))
            assert fixture.query(f"SELECT actor {queue}", characters) == str(actor)
            original = actor & 0xFFFFFF
        elif phase == "before-enqueue":
            assert not fixture.query(f"SELECT actor {queue}", characters)
            assert not fixture.query(f"SELECT actor {actors}", characters)
            assert f"[cast result] {SPELL}: ok" not in player_log()
            assert f"[spell go] {SPELL} by" not in player_log()
        else:
            assert fixture.query(f"SELECT actor {queue}", characters) == "0"
            assert not fixture.query(f"SELECT actor {actors}", characters)
        observer_offset = len(observer_log())
        recovered_log = player_log if phase == "before-enqueue" else observer_log
        recovery_offset = len(recovered_log())
        drop(caster_worker if phase == "before-enqueue" else object_worker)
        fixture.query(f"KILL CONNECTION {connection}")
        fixture.query("DROP TRIGGER hold_object", characters)

    def bundles(output):
        return set(map(int, re.findall(rf"\[game object\] {OBJECT} guid (\d+):", output)))

    wait_for("the original gateway connection to reload", lambda: f"[new world] map {map_id} " in
             recovered_log()[recovery_offset:], 40)
    if phase == "before-enqueue":
        assert not fixture.query(f"SELECT actor {actors}", characters)
        retry.touch()
    recovered, = wait_for("the original observer to see the recovered bundle",
                          lambda: bundles(observer_log()[observer_offset:]), 15)
    assert original is None or recovered == original
    assert bundles(observer_log()) == {recovered}
    assert fixture.query(f"SELECT actor & 16777215 {actors}", characters) == str(recovered)
    wait_for("the publication receipt to retire", lambda: fixture.query(f"SELECT COUNT(*) {queue}", characters) == "0", 6)
    use.touch()
    wait_for("the recovered bundle to serve as a spell focus",
             lambda: f"[spell go] {FOCUS_SPELL} by" in observer_log(), 10)
    if phase == "after":
        assert_expired(fixture, characters, actors, observer_log, observer_offset, recovered, started)
    finish.touch()
    assert player.wait(timeout=25) == observer.wait(timeout=25) == 0
    print(f"PASS: {phase} crash, one Relic Bundle {recovered} recovered and used as a spell focus")


def assert_expired(fixture, characters, actors, log, offset, guid, started):
    short_guid = ((OBJECT & 0xFF) << 24) | guid
    gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
    appearance = f"[game object] {OBJECT} guid {guid}:"
    expiry = started + DURATION
    wait_for("the bundle to expire at the original deadline", lambda: gone.search(log()[offset:].rsplit(appearance, 1)[1]),
             max(1, expiry + 4 - time.monotonic()))
    assert abs(time.monotonic() - expiry) < 4
    wait_for("the expired bundle checkpoint to retire", lambda: fixture.query(f"SELECT COUNT(*) {actors}", characters) == "0", 6)


def run_idle(fixture):
    fixture.base["grid_cleanup_delay_seconds"] = 1
    world = fixture.world_with_writable_tables("spell_template")
    fixture.query(f"UPDATE spell_template SET DurationIndex=325,RequiresSpellFocus=0,EffectImplicitTargetA1=18 "
                  f"WHERE Id={SPELL}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    x, y, z = -8901.6, -162.6, 82.0
    away_x = x + 400
    fixture.query(f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z} WHERE guid={leader}", characters)
    cast, leave, return_to_cell, finish = (fixture.directory / name for name in ("cast", "leave", "return", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(cast), f"cmd:.debug castself {SPELL}", wait(leave),
                    f"worldport:0:{away_x}:{y}:{z}", wait(return_to_cell), f"worldport:0:{x}:{y}:{z}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3500:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {y:.1f})"
    wait_for("the original client to reach its region worker",
             lambda: any(arrival in fixture.log(tag) for tag in ("node1", "node2", "node3")), 20)
    started = time.monotonic()
    cast.touch()
    guid = int(wait_for("the original bundle", lambda: re.search(rf"\[game object\] {OBJECT} guid (\d+):", log()), 10)[1])
    actors = f"FROM dmangos_quest_actor WHERE realm=1 AND player=0 AND (actor & 16777215)={guid}"
    wait_for("the bundle checkpoint", lambda: fixture.query(f"SELECT COUNT(*) {actors}", characters) == "1", 6)
    leave.touch()
    wait_for("the player to leave the bundle's grid", lambda: any(marker in log() for marker in
             (f"[teleport] to {away_x:.1f}", f"[new world] map 0 at {away_x:.1f}")), 12)
    time.sleep(14)  # The map scans idle cells every ten seconds.
    assert fixture.query(f"SELECT COUNT(*) {actors}", characters) == "1", "idle cleanup discarded the live bundle"
    offset = len(log())
    return_to_cell.touch()
    wait_for("the returning player to see the original bundle", lambda: f"[game object] {OBJECT} guid {guid}:" in log()[offset:], 10)
    assert_expired(fixture, characters, actors, log, offset, guid, started)
    finish.touch()
    assert player.wait(timeout=25) == 0
    print(f"PASS: the original bundle {guid} survived an idle grid and expired on schedule")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("before-enqueue", "sender", "during", "after", "idle"))
    args = parser.parse_args()
    if args.phase == "idle":
        run_test("outdoor-object-idle", run_idle)
    elif args.phase:
        run_test(f"outdoor-object-{args.phase}", lambda fixture: run_creation(fixture, args.phase))
    else:
        run_test("outdoor-object-recovery", run)
