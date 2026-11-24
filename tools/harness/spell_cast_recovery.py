#!/usr/bin/env python3
"""Kill a worker during a Fireball cast and check that it resolves once."""

import argparse
import math
import re
import signal
import struct

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait
from group_loot import round_positions


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


def remote_bounce(fixture):
    spell, primary, bounce = 421, 38, 46  # Chain Lightning, Defias Thug, Murloc
    world = fixture.world_with_writable_tables("spell_template", "creature")
    fixture.query(f"UPDATE spell_template SET CastingTimeIndex=1,Speed=0.12 WHERE Id={spell}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    fixture.query(f"INSERT INTO character_spell (guid,spell) VALUES ({leader},{spell})", characters)

    def regions(node):
        ownership = re.findall(r"this node owns \[([^]]*)\]", fixture.log(f"node{node}"))
        return set(map(int, re.findall(r"\d+", ownership[-1]))) if ownership else set()

    def ownership():
        known = {node: regions(node) for node in (2, 3, 1)}
        return known if all(known.values()) else None

    owned = wait_for("all three workers to hold regions", ownership, 30)
    map_id, (host, x, y), (target_host, tx, ty), _ = round_positions(fixture.log("node1"), owned)
    cast_x, cast_y = x + x - tx, y + y - ty
    facing = math.atan2(y - cast_y, x - cast_x) % math.tau
    z = 200
    fixture.query(f"UPDATE characters SET map={map_id},position_x={cast_x},position_y={cast_y},"
                  f"position_z={z},orientation={facing} WHERE guid={leader}", characters)
    for worker, px, py, entry in ((host, x, y, primary), (target_host, tx, ty, bounce)):
        fixture.query(f"UPDATE characters SET map={map_id},position_x={px},position_y={py},position_z={z} "
                      f"WHERE name='{names[1]}'", characters)
        label = f"spawn-{entry}"
        spawn = client(label, 1, f"login:{names[1]}", "cmd:.cheat god", f"cmd:.npc spawn {entry}", "logout")
        assert spawn.wait(timeout=25) == 0, fixture.log(label)
        arrival = f"'{names[1]}' arrived from another node (map {map_id} at {px:.1f} {py:.1f})"
        assert arrival in fixture.log(f"node{worker}"), f"spawn {entry} was assigned to the wrong worker"

    def guid(entry, px, py):
        return int(fixture.query(f"SELECT MAX(guid) FROM creature WHERE map={map_id} AND id={entry} "
                                 f"AND ABS(position_x-({px}))<0.5 AND ABS(position_y-({py}))<0.5", world))

    primary_guid, bounce_guid = guid(primary, x, y), guid(bounce, tx, ty)
    cast, finish = (fixture.directory / flag for flag in ("cast", "finish"))
    player = client("player", 0, f"login:{names[0]}", "cmd:.cheat god", "cmd:.cheat power", wait(cast),
                    f"cast:{spell}:{primary}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {cast_x:.1f} {cast_y:.1f})"
    wait_for("the caster's assigned worker", lambda: arrival in fixture.log(f"node{host}"), 25)
    wait_for("the two original targets", lambda: f"guid {primary_guid}:" in log() and f"guid {bounce_guid}:" in log(), 10)
    cast.touch()
    spell_go = f"[spell go] {spell} by {leader}"
    wait_for("the original Chain Lightning launch", lambda: spell_go in log(), 6)
    hit = re.compile(rf"\[spell damage\] {spell}: \d+ to ({primary_guid}|{bounce_guid})\b")
    assert not hit.search(log())
    checkpoint = f"SELECT state FROM dmangos_player_summons WHERE player={leader}"
    payload = bytes.fromhex(wait_for("the projectile checkpoint", lambda: fixture.query(checkpoint, characters), 4))
    # Skip the gateway identity, summons, fishing, ground spell, cast header, and local missiles.
    offset = struct.calcsize("<BHQ")
    for _ in range(4 if payload[0] >= 5 else 3):
        length, = struct.unpack_from("<I", payload, offset)
        offset += 4 + length
    offset += struct.calcsize("<IIIi7i")
    for _ in range(2):
        length, = struct.unpack_from("<I", payload, offset)
        offset += 4 + length
    assert offset < len(payload) and struct.unpack_from("<I", payload, offset)[0] == 1, "missing remote bounce in save"
    offset = len(log())
    nodes[f"node{host}"].send_signal(signal.SIGKILL)
    assert nodes[f"node{host}"].wait(timeout=10) == -signal.SIGKILL
    wait_for("the original client to reload", lambda: f"[new world] map {map_id} " in log()[offset:], 45)
    wait_for("the bounce to reach its other worker after the kill",
             lambda: str(bounce_guid) in hit.findall(log()[offset:]), 22)
    wait_for("the finished projectiles to clear their checkpoint", lambda: not fixture.query(checkpoint, characters), 7)
    finish.touch()
    assert player.wait(timeout=20) == 0
    output = fixture.log("player")
    assert output.count(spell_go) == 1 and hit.findall(output).count(str(bounce_guid)) == 1
    assert nodes[f"node{target_host}"].poll() is None
    print(f"PASS: killed caster worker {host} before Chain Lightning reached its target on worker {target_host}, "
          "then saw the original bounce land once")


def periodic_channel(fixture, canceled):
    spell = 5143  # Arcane Missiles
    world = fixture.world_with_writable_tables("spell_template", "creature", "creature_template")
    target, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE map=0 "
                                    f"AND id={TARGET} ORDER BY guid LIMIT 1", world).split()
    x = float(x) + 4
    fixture.query(f"UPDATE spell_template SET DurationIndex=18 WHERE Id={spell}; "
                  f"UPDATE creature SET MovementType=0,spawndist=0 WHERE guid={target}; "
                  f"UPDATE creature_template SET HealthMultiplier=60 WHERE entry={TARGET}", world)
    missile = int(fixture.query(f"SELECT EffectTriggerSpell1 FROM spell_template WHERE Id={spell}", world))
    assert missile
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world,
                                                               leader_appearance=(1, 8))
    fixture.query(f"INSERT IGNORE INTO character_spell (guid,spell) VALUES ({leader},{spell}); "
                  f"UPDATE characters SET map=0,position_x={x},position_y={y},position_z={z},orientation=PI() "
                  f"WHERE guid={leader}", characters)
    cast, cancel, finish = (fixture.directory / flag for flag in ("cast", "cancel", "finish"))
    cancel_commands = (wait(cancel), f"cancelchannel:{spell}") if canceled else ()
    player = client("player", 0, f"login:{names[0]}", "cmd:.cheat god", "cmd:.cheat power", wait(cast),
                    f"cast:{spell}:{TARGET}", *cancel_commands, wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll() is not None:
            raise RuntimeError(output[-3000:])
        return output

    arrival = f"'{names[0]}' arrived from another node (map 0 at {x:.1f} {float(y):.1f})"
    host = wait_for("the caster's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 30)
    cast.touch()
    started = re.compile(rf"\[channel start\] {spell} for (\d+) ms")
    hit = re.compile(rf"\[spell damage\] {missile}: \d+ to {target}\b")
    wait_for("the original channel and a missile hit", lambda: started.search(log()) and hit.search(log()), 6)
    checkpoint = f"SELECT COUNT(*) FROM dmangos_player_summons WHERE player={leader}"
    if canceled:
        cancel.touch()
        wait_for("the interrupted channel to clear its checkpoint",
                 lambda: "[channel update] 0 ms" in log() and fixture.query(checkpoint, characters) == "0", 5)
    offset = len(log())
    nodes[host].kill()
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL

    def recovered():
        new = log()[offset:]
        return new.partition("[new world] map 0 ")[2]

    wait_for("the original gateway client to reload", lambda: "[appears] player" in recovered(), 35)
    if not canceled:
        resumed = wait_for("remaining channel and another missile on the original client",
                           lambda: hit.search(recovered()) and started.search(recovered()), 12)
        assert 0 < int(resumed[1]) < 20_000
        wait_for("the original channel to end", lambda: "[channel update] 0 ms" in recovered(), 22)
    finish.touch()
    assert player.wait(timeout=20) == 0
    output = fixture.log("player")
    assert output.count(f"[spell go] {spell} by {leader}") == 1
    if canceled:
        assert not started.search(output[offset:]) and not hit.search(output[offset:])
    print(f"PASS: killed caster worker {host} with Arcane Missiles " + ("canceled" if canceled else "still channeling"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument("--finished", action="store_true", help="kill the worker after the cast finishes")
    phase.add_argument("--projectile", action="store_true", help="kill the worker after launch but before impact")
    phase.add_argument("--remote-bounce", action="store_true", help="recover a Chain Lightning bolt to another worker")
    phase.add_argument("--channel", action="store_true", help="recover active Arcane Missiles")
    phase.add_argument("--channel-canceled", action="store_true", help="kill the worker after Arcane Missiles is canceled")
    args = parser.parse_args()
    if args.remote_bounce:
        test = remote_bounce
    elif args.channel or args.channel_canceled:
        def test(fixture):
            return periodic_channel(fixture, args.channel_canceled)
    else:
        def test(fixture):
            return run(fixture, args.finished, args.projectile)
    run_test("spell-cast-recovery", test)
