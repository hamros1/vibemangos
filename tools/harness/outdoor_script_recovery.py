#!/usr/bin/env python3
"""Exercise outdoor script handoff and worker crashes around summon and credit saves."""

import argparse
import re
import signal
import struct
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import start_cluster, wait


ACTOR, QUEST, SUMMON = 197, 7, 5955
QUEST_START = 0  # DbScriptType.questStart


def run(fixture, clean, after_summon, retry_actor_db, killed_actor, summon_commit=None):
    writable = ["quest_template", "dbscripts_on_quest_start"]
    if summon_commit:
        writable += ["creature_spawn_data_template", "dbscripts_on_relay"]
    world = fixture.world_with_writable_tables(*writable)
    guid, map_id, x, y, z = fixture.query(
        f"SELECT guid,map,position_x,position_y,position_z FROM creature WHERE id={ACTOR} ORDER BY guid LIMIT 1",
        world).split()
    script = 8_910_004
    checkpoint_prefix = struct.pack("<BI", QUEST_START, script).hex()
    checkpoint = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{checkpoint_prefix}%'"
    first, last = f"[emote] {guid}: 66", f"[emote] {guid}: 23"
    summon_delay = 4000 if summon_commit else 0 if after_summon else 12000
    summon_ms = 36000 if summon_commit == "after" else 60000
    buddy_entry, search_radius = (SUMMON, 30) if summon_commit else (0, 0)
    fixture.query(
        f"UPDATE quest_template SET StartScript={script} WHERE entry={QUEST}; "
        "INSERT INTO dbscripts_on_quest_start "
        "(id,delay,priority,command,datalong,datalong2,x,y,z,buddy_entry,search_radius,comments) "
        f"VALUES ({script},0,0,1,66,0,0,0,0,0,0,'Recovery first step'),"
        f"({script},{summon_delay},1,10,{SUMMON},{summon_ms},{float(x) + 4},{y},{z},0,0,'Recovery summon'),"
        f"({script},12000,2,1,23,0,0,0,0,{buddy_entry},{search_radius},'Recovery last step')", world)
    if summon_commit:
        relay = script + 1
        relay_prefix = struct.pack("<BI", 3, relay).hex()  # DbScriptType.relay
        relay_row = f"FROM dmangos_outdoor_script WHERE realm=1 AND state LIKE '{relay_prefix}%'"
        fixture.query(f"INSERT INTO creature_spawn_data_template (Entry,Name,RelayId) "
                      f"VALUES ({relay},'Recovery summon relay',{relay}); "
                      f"INSERT INTO dbscripts_on_relay (id,delay,command,datalong,comments) "
                      f"VALUES ({relay},7000,1,24,'Recovery summon emote'); "
                      f"UPDATE dbscripts_on_quest_start SET dataint4={relay} WHERE id={script} AND command=10", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1)",
                  characters)
    player_x = float(x) + 1
    fixture.query(f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    summon_row = ("FROM dmangos_quest_actor WHERE realm=1 AND player=0 "
                  f"AND (actor >> 24) & 16777215 = {SUMMON}")
    if summon_commit == "during":
        fixture.query("CREATE TRIGGER hold_summon BEFORE INSERT ON dmangos_quest_actor FOR EACH ROW "
                      f"SET @hold_summon = IF((NEW.actor >> 24) & 16777215 = {SUMMON}, SLEEP(60), 0)", characters)
    if clean and after_summon:
        fixture.query(f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                      f"WHERE guid<>{leader}", characters)
    start, finish, kill = (fixture.directory / flag for flag in ("start", "finish", "kill"))
    actions = (wait(kill), f"targetnpc:{SUMMON}", "cmd:.kill") if killed_actor else ()
    player = client("player", 0, f"login:{names[0]}", wait(start), f"questaccept:{ACTOR}:{QUEST}",
                    *actions, wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll():
            raise RuntimeError(output[-3000:])
        return output

    wait_for("the quest giver", lambda: f"[creature] {ACTOR} guid {guid}:" in log(), 20)
    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    host = wait_for("the player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 20)
    start.touch()
    wait_for("the immediate emote", lambda: first in log(), 12)

    def actor_guids(output):
        return set(re.findall(rf"\[creature\] {SUMMON} guid (\d+):", output))

    def followed_summon(output):
        return any(all(f"[emote] {actor}: {emote}\n" in output for emote in (23, 24))
                   for actor in actor_guids(output))

    blocked = None
    if summon_commit == "during":
        schema = characters.rsplit(";", 1)[-1]
        blocked = wait_for("the summon inside its database write", lambda: fixture.query(
            "SELECT ID FROM information_schema.PROCESSLIST "
            f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_summon =%'"), 12)
        assert blocked.isdecimal(), blocked
        assert fixture.query(f"SELECT COUNT(*) {summon_row}", characters) == "0"
    if after_summon:
        original, = wait_for("the original actor", lambda: actor_guids(log()), 8)
        first_seen = time.monotonic()
        actor_checkpoint = ("SELECT COUNT(*) FROM dmangos_quest_actor WHERE realm=1 AND player=0 "
                            f"AND (actor & 16777215)={original}")
        wait_for("the original actor checkpoint", lambda: fixture.query(actor_checkpoint, characters) == "1", 8)
        if killed_actor:
            kill.touch()
            wait_for("the dead actor checkpoint to be retired", lambda: fixture.query(actor_checkpoint, characters) == "0", 8)
    cursor = fixture.query(f"SELECT `cursor` {checkpoint}", characters)
    if not blocked:
        assert cursor == ("2" if after_summon else "1"), cursor
    if summon_commit == "after":
        assert fixture.query(f"SELECT `cursor` {relay_row}", characters) == "0"
    elif blocked:
        assert fixture.query(f"SELECT COUNT(*) {relay_row}", characters) == "0"
    else:
        assert last not in log()
    offset = len(log())
    if retry_actor_db:
        fixture.query("RENAME TABLE dmangos_quest_actor TO held_quest_actor", characters)
    nodes[host].send_signal(signal.SIGTERM if clean else signal.SIGKILL)
    assert nodes[host].wait(timeout=25) == (0 if clean else -signal.SIGKILL)
    if blocked:
        fixture.query(f"KILL CONNECTION {blocked}")
        fixture.query("DROP TRIGGER hold_summon", characters)
    if not clean:
        wait_for("the existing client to reload through the gateway",
                 lambda: f"[new world] map {map_id} " in log()[offset:], 40)
    if retry_actor_db:
        wait_for("the replacement's failed first checkpoint read", lambda: any(
            "could not load outdoor quest actors" in fixture.log(tag) for tag in nodes if tag != host), 10)
        fixture.query("RENAME TABLE held_quest_actor TO dmangos_quest_actor", characters)
    def resumed():
        output = log()[offset:]
        if summon_commit:
            return followed_summon(output)
        return last in output and (killed_actor or (after_summon and clean) or actor_guids(output))

    wait_for("the delayed summon and emote to resume", resumed, 20)
    if summon_commit:
        recovered, = actor_guids(log()[offset:])
        last = f"[emote] {recovered}: 23"
        assert log().count(f"[emote] {recovered}: 24\n") == 1
        assert fixture.query(f"SELECT COUNT(*) {relay_row}", characters) == "0"
    assert log().count(first) == log().count(last) == 1
    if after_summon:
        assert actor_guids(log()) == {original}
        if killed_actor:
            assert not actor_guids(log()[offset:]), "the dead actor was resurrected"
        elif clean:
            observing = client("observer", 1, f"login:{names[1]}", wait(finish), "logout")
            wait_for("a new client to see the original actor on its new worker",
                     lambda: actor_guids(fixture.log("observer")) == {original}, 15)
        else:
            assert actor_guids(log()[offset:]) == {original}
    else:
        assert len(actor_guids(log()[offset:])) == 1
    if blocked:
        assert cursor == "1" and not actor_guids(log()[:offset]), "the uncommitted summon became visible"
        original, = actor_guids(log())
        assert fixture.query(f"SELECT actor & 16777215 {summon_row}", characters) == original
    assert fixture.query(f"SELECT COUNT(*) {checkpoint}", characters) == "0"
    assert fixture.query(f"SELECT status FROM character_queststatus WHERE guid={leader} AND quest={QUEST}",
                         characters) == "3"
    if summon_commit == "after":
        short_guid = ((SUMMON & 0xFF) << 24) | int(original)
        gone = re.compile(rf"\[out of range\] (?:\d+, )*{short_guid}(?:,|$)", re.MULTILINE)
        appearance = f"[creature] {SUMMON} guid {original}:"
        expiry = first_seen + summon_ms / 1000

        def expired():
            return gone.search(log()[offset:].rsplit(appearance, 1)[1])

        wait_for("the recovered actor to expire on its original schedule", expired, max(1, expiry + 3 - time.monotonic()))
        assert abs(time.monotonic() - expiry) < 3, "the recovered summon expired outside its original lifetime"
        assert actor_guids(log()) == {original}
        wait_for("the expired actor checkpoint to be deleted", lambda: fixture.query(
            f"SELECT COUNT(*) {summon_row}", characters) == "0", 5)
    finish.touch()
    if player.wait(timeout=25):
        raise RuntimeError(fixture.log("player")[-3000:])
    if clean and after_summon:
        assert observing.wait(timeout=25) == 0
    if summon_commit == "during":
        print(f"PASS: killed {host} during summon commit, created one actor on retry and resumed the original socket")
    elif summon_commit == "after":
        print(f"PASS: killed {host} after summon commit, kept the original actor and expiry on the same socket")
    else:
        action = "drained" if clean else "killed"
        print(f"PASS: {action} {host} between steps, preserved one summon and resumed the emote on the original socket")


def run_credit(fixture, credit):
    fixture.base["player_save_interval"] = 2
    world = fixture.world_with_writable_tables("quest_template", "dbscripts_on_quest_start")
    guid, map_id, x, y, z = fixture.query(
        f"SELECT guid,map,position_x,position_y,position_z FROM creature WHERE id={ACTOR} ORDER BY guid LIMIT 1",
        world).split()
    script, entry = 8_910_005, 6
    explore = credit == "explore"
    command, data = (7, QUEST) if explore else (8, entry)
    following_step = "" if explore else f",({script},6000,2,1,23,'Credit ending emote')"
    fixture.query(
        f"UPDATE quest_template SET StartScript={script}, SpecialFlags={2 if explore else 0}, "
        f"ReqCreatureOrGOId1={0 if explore else entry}, ReqCreatureOrGOCount1={0 if explore else 2} WHERE entry={QUEST}; "
        "INSERT INTO dbscripts_on_quest_start (id,delay,priority,command,datalong,comments) "
        f"VALUES ({script},0,0,1,66,'Credit starting emote'),"
        f"({script},6000,1,{command},{data},'Delayed quest credit'){following_step}", world)
    characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=True, world=world)
    previous = int(fixture.query(f"SELECT PrevQuestId FROM quest_template WHERE entry={QUEST}", world))
    player_x = float(x) + 1
    fixture.query(f"INSERT INTO character_queststatus (guid,quest,status,rewarded) VALUES ({leader},{previous},1,1); "
                  f"UPDATE characters SET map={map_id},position_x={player_x},position_y={y},position_z={z} "
                  f"WHERE guid={leader}", characters)
    changed = "NEW.explored = 1" if explore else "NEW.mobcount1 = 1"
    fixture.query(f"CREATE TRIGGER hold_credit BEFORE INSERT ON character_queststatus FOR EACH ROW "
                  f"SET @hold_credit = IF(NEW.guid={leader} AND NEW.quest={QUEST} AND {changed}, SLEEP(60), 0)",
                  characters)
    start, finish = (fixture.directory / flag for flag in ("start", "finish"))
    player = client("player", 0, f"login:{names[0]}", wait(start), f"questaccept:{ACTOR}:{QUEST}", wait(finish), "logout")

    def log():
        output = fixture.log("player")
        if player.poll():
            raise RuntimeError(output[-3000:])
        return output

    wait_for("the quest giver", lambda: f"[creature] {ACTOR} guid {guid}:" in log(), 20)
    arrival = f"'{names[0]}' arrived from another node (map {map_id} at {player_x:.1f} {float(y):.1f})"
    host = wait_for("the player's worker", lambda: next((tag for tag in ("node1", "node2", "node3")
                    if arrival in fixture.log(tag)), ""), 20)
    start.touch()
    schema = characters.rsplit(";", 1)[-1]
    connection = wait_for("quest credit inside its database write", lambda: fixture.query(
        "SELECT ID FROM information_schema.PROCESSLIST "
        f"WHERE DB='{schema}' AND STATE='User sleep' AND INFO LIKE 'SET @hold_credit =%'"), 30)
    assert connection.isdecimal(), connection
    query = f"SELECT status,explored,mobcount1 FROM character_queststatus WHERE guid={leader} AND quest={QUEST}"
    assert fixture.query(query, characters) == "3\t0\t0"
    offset = len(log())
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL
    fixture.query(f"KILL CONNECTION {connection}")
    fixture.query("DROP TRIGGER hold_credit", characters)
    last = f"[emote] {guid}: 23"
    wait_for("the original client to reload through the gateway",
             lambda: f"[new world] map {map_id} " in log()[offset:], 40)
    expected = "1\t1\t0" if explore else "3\t0\t1"
    packet = f"[quest objectives done] {QUEST}" if explore else f"[quest kill] {QUEST}: {entry} 1/2"
    wait_for("the original step to persist quest credit exactly once",
             lambda: fixture.query(query, characters) == expected and packet in log()[offset:]
             and (explore or last in log()[offset:]), 15)
    assert packet not in log()[:offset]
    if not explore:
        assert log().count(last) == log().count(packet) == 1, log()[-3000:]
    assert fixture.query("SELECT COUNT(*) FROM dmangos_outdoor_script WHERE realm=1", characters) == "0"
    finish.touch()
    if player.wait(timeout=25):
        raise RuntimeError(fixture.log("player")[-3000:])
    assert fixture.query(query, characters) == expected
    print(f"PASS: killed {host} during {credit} credit; the original client resumed and received credit once")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    transfer = parser.add_mutually_exclusive_group()
    transfer.add_argument("--clean", action="store_true", help="drain the worker instead of killing it")
    transfer.add_argument("--retry-actor-db", action="store_true", help="interrupt the replacement's first actor checkpoint read")
    transfer.add_argument("--dead-actor", action="store_true", help="kill the script's actor before killing the worker")
    transfer.add_argument("--kill-during-credit", choices=("kill", "explore"),
                          help="kill the worker during the delayed step's quest credit write")
    transfer.add_argument("--summon-commit", choices=("during", "after"),
                          help="kill the worker during or just after the actor checkpoint write")
    parser.add_argument("--after-summon", action="store_true", help="crash after the script created its actor")
    args = parser.parse_args()
    label = "outdoor-script-handoff" if args.clean else "outdoor-script-recovery"
    if args.kill_during_credit:
        run_test(f"outdoor-quest-{args.kill_during_credit}", lambda fixture: run_credit(fixture, args.kill_during_credit))
    else:
        if args.summon_commit and args.after_summon:
            parser.error("--after-summon selects the legacy scenario; use --summon-commit by itself")
        if args.summon_commit:
            label = f"outdoor-summon-{args.summon_commit}"
        after = args.after_summon or args.retry_actor_db or args.dead_actor or args.summon_commit == "after"
        run_test(label, lambda fixture: run(fixture, args.clean, after, args.retry_actor_db, args.dead_actor,
                                          args.summon_commit))
