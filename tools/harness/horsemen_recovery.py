#!/usr/bin/env python3
"""Kill the Naxxramas worker during the Four Horsemen's fight and resume it in the same raid copy on the same sockets.

Three scripted raid members (GMs, on a gateway) slay Gothik, so that the Horsemen's door opens and closes with their
fight, and come into the Horsemen's room: two by the Horsemen, the third by the door, to watch it.

    --phase kills  the leader pulls the four, hurts Thane Korth'azz and Sir Zeliek, and slays Lady Blaumeux and
                   Highlord Mograine; the worker dies just after the checkpoint of the second death. All three
                   original sockets come back to the same copy: the slain still dead and their spirits there, the
                   survivors (the same creatures) at their health, marking on the timers they had, the spirits
                   marking too, the members still marked and the door shut. The last two slain, the door and the
                   quarter's portal open and one chest appears; the worker that took over dies just after the
                   checkpoint of the last death, and the same single chest, the open door and the dead four are there
                   after recovery.
    --phase wipe   Blaumeux and Mograine slain, the raid dies: the four are home again and the door open. The worker
                   dies just after the checkpoint of the wipe. After recovery the four are there, alive, with no
                   spirit, and the door open; pulled again and slain, they leave one chest.
"""

import argparse
import re
import time

from cluster_fixture import run_test, wait_for
from dungeon_recovery import open_party, start_cluster
from sapphiron_recovery import ATTUNEMENT, MAP, checkpoints, kill_host, newer_checkpoint


GOTHIK = 16060
BLAUMEUX, MOGRAINE, KORTHAZZ, ZELIEK = 16065, 16062, 16064, 16063
HORSEMEN = (BLAUMEUX, MOGRAINE, KORTHAZZ, ZELIEK)
SPIRITS = {BLAUMEUX: 16776, MOGRAINE: 16775, KORTHAZZ: 16778, ZELIEK: 16777}
MARKS = {BLAUMEUX: 28833, MOGRAINE: 28834, KORTHAZZ: 28832, ZELIEK: 28835}
DOOR, CHEST, PORTAL = 181119, 181366, 181578
GOTHIK_BALCONY = (2638.0, -3386.0, 285.6)
BY_HORSEMEN = (2557.0, -2987.0, 242.0)  # in their sight (they see 80 yards): coming there is the pull
BY_DOOR = (2562.0, -2992.0, 241.4)  # below their platform, out of their sight
MARK_EVERY, FIRST_MARK = 12, 20


def creatures(log, entry, living=True):
    """The spawn guids of `entry` the client was shown (alive, unless `living` is False)."""
    shown = {int(guid): int(health) for guid, health in
             re.findall(rf"\[creature\] {entry} guid (\d+): .*?health (\d+),", log)}
    dead = {int(guid) & 0xFFFFFF for guid in re.findall(r"\[changes\] (\d+): fields .*?health 0/", log)}
    return {guid for guid, health in shown.items() if not living or (health > 0 and guid not in dead)}


def unit_guid(entry, spawn):
    return (0xF130 << 48) | (entry << 24) | spawn


def health(log, entry, spawn):
    """The last health of creature `spawn` the client was told."""
    shown = re.findall(rf"\[creature\] {entry} guid {spawn}: .*?health (\d+),", log)
    changed = re.findall(rf"\[changes\] {unit_guid(entry, spawn)}: fields .*?health (\d+)/", log)
    return int(changed[-1]) if changed else int(shown[-1]) if shown else None


def top_health(log, entry, spawn):
    """The health the client was first shown of creature `spawn` (whole, before the fight)."""
    return int(re.findall(rf"\[creature\] {entry} guid {spawn}: .*?health (\d+),", log)[0])


def died(log, entry, spawn):
    """Whether `log` tells of creature `spawn`'s death (its health 0)."""
    return re.search(rf"\[changes\] {unit_guid(entry, spawn)}: fields .*?health 0/", log) is not None


def objects(log, entry):
    return set(map(int, re.findall(rf"\[game object\] {entry} guid (\d+):", log)))


def door_state(log):
    """The Horsemen's door's last state the client was told (0 open, 1 shut), or None."""
    created = re.findall(rf"\[game object\] {DOOR} guid (\d+): .*?state (\d+)", log)
    if not created:
        return None
    guid, state = int(created[-1][0]), created[-1][1]
    rest = log.rsplit(f"[game object] {DOOR} guid {guid}:", 1)[1]
    for full, changed in re.findall(r"\[game object state\] (0x[0-9a-f]+) state (\d+)", rest):
        if int(full, 16) & 0xFFFFFF == guid:
            state = changed
    return int(state)


def marked(log, entry, spawn):
    return f"[spell go] {MARKS[entry]} by {spawn}" in log


def port(spot):
    return f"worldport:{MAP}:{spot[0]}:{spot[1]}:{spot[2]}"


class Raid:
    """Three raid members in the Horsemen's room, driven stage by stage."""

    def __init__(self, fixture):
        self.fixture = fixture
        characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=False, raid=True,
                                                                     extra_member=True)
        self.characters, self.names, self.nodes = characters, names, nodes
        self.guids = [int(fixture.query(f"SELECT guid FROM characters WHERE name='{name}'", characters))
                      for name in names]
        fixture.query("INSERT INTO character_queststatus (guid, quest, status, rewarded) VALUES "
                      + ",".join(f"({guid},{ATTUNEMENT},1,1)" for guid in self.guids), characters)
        first = [fixture.directory / f"stage-0-{member}" for member in range(3)]
        actions = [(f"waitactions:{first[member]}",) for member in range(3)]
        self.copy, self.logs, self.clients = open_party(fixture, characters, names, leader, client, nodes, False,
                                                        actions, map_id=MAP, entrance=port(GOTHIK_BALCONY))
        self.next = first
        self.number = 0

    def stage(self, actions):
        """Each member's next actions (a list per member), written at once; each waits for its next stage after."""
        self.number += 1
        for member in range(3):
            path = self.next[member]
            following = self.fixture.directory / f"stage-{self.number}-{member}"
            path.write_text("\n".join([*actions[member], f"waitactions:{following}"]) + "\n")
            self.next[member] = following

    def finish(self):
        for path in self.next:
            path.write_text("logout\n")
        for i, process in enumerate(self.clients):
            if process.wait(timeout=30):
                raise RuntimeError(self.logs()[i][-4000:])

    def checkpoints(self):
        return checkpoints(self.fixture, self.nodes, self.copy)

    def next_checkpoint(self, before, why, seconds):
        return wait_for(why, lambda: newer_checkpoint(self.fixture, self.nodes, self.copy, before), seconds)

    def same_copy(self):
        fixture, characters = self.fixture, self.characters
        assert fixture.query(f"SELECT id FROM instance WHERE map={MAP}", characters) == str(self.copy), \
            "a second raid copy"
        assert fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={self.copy}",
                             characters) == "3"

    def crash(self, host):
        """Kills `host` and waits for the three original sockets to come back to the copy; their logs since."""
        offsets = list(map(len, self.logs()))
        kill_host(self.nodes, host)

        def recovered():
            parts = [log[offset:] for log, offset in zip(self.logs(), offsets)]
            if all(f"[new world] map {MAP} " in part and "[appears] player" in part for part in parts):
                return parts

        wait_for("the three original sockets back in the copy", recovered, 60)
        back = time.monotonic()
        self.same_copy()
        return back, lambda: [log[offset:] for log, offset in zip(self.logs(), offsets)]

    def restart(self, host):
        """Starts the killed `host` again (a new incarnation, its own log), and waits for it to hold a lease."""
        from cluster_fixture import WORLD

        again = f"{host}-again"
        self.nodes[again] = self.fixture.start(again, [WORLD, "-c", self.fixture.directory / f"{host}.json"])
        wait_for(f"{host} back in the cluster", lambda: "lease holds" in self.fixture.log(again), 45)

    def seen(self, entry, living=True):
        return set().union(*(creatures(log, entry, living) for log in self.logs()))

    def into_the_room(self):
        """Gothik slain (his exit and the Horsemen's door open), then the third member by the door, to watch it."""
        self.stage([[f"killpack:{GOTHIK}"], [], []])
        wait_for("Gothik slain", lambda: self.seen(GOTHIK, living=False) and not self.seen(GOTHIK), 10)
        self.stage([[], [], [port(BY_DOOR)]])
        spawns = wait_for("the four in sight", lambda: (lambda found: found if all(found.values()) else None)(
            {entry: self.seen(entry) for entry in HORSEMEN}), 10)
        wait_for("the door open, seen by the member at it", lambda: door_state(self.logs()[2]) == 0, 10)
        return {entry: next(iter(found)) for entry, found in spawns.items()}

    def pull(self, four):
        """The other two come before the four and fight them; returns, once each horseman has marked, when the leader
        saw each one's first mark."""
        offset = len(self.logs()[0])
        self.stage([[port(BY_HORSEMEN), f"attack:{KORTHAZZ}"],
                    [port((BY_HORSEMEN[0] + 1, BY_HORSEMEN[1] + 2, BY_HORSEMEN[2])), f"attack:{ZELIEK}"], []])
        wait_for("the door shut with the fight", lambda: door_state(self.logs()[2]) == 1, 8)
        first = {}

        def all_marked():
            for entry in HORSEMEN:
                if entry not in first and marked(self.logs()[0][offset:], entry, four[entry]):
                    first[entry] = time.monotonic()
            return len(first) == len(HORSEMEN)

        wait_for("each horseman's first mark", all_marked, FIRST_MARK + 6)
        return first

    def slay(self, *entries):
        self.stage([[f"killpack:{entry}" for entry in entries], [], []])

    def slay_saved(self, entry, spawn):
        """The leader slays horseman `entry`; the node that saved the checkpoint of his death. The checkpoints before
        it are all in first (one comes late, after its death is seen), so the next one is his death's."""
        time.sleep(1)
        before = self.checkpoints()
        self.slay(entry)
        wait_for(f"horseman {entry} slain", lambda: spawn not in self.seen(entry), 6)
        return self.next_checkpoint(before, f"the checkpoint of horseman {entry}'s death", 4)


def kills(fixture):
    raid = Raid(fixture)
    four = raid.into_the_room()
    first_marks = raid.pull(four)
    # The leader hurts the two that live on: a level 60 warrior hardly touches them.
    tops = {entry: top_health(raid.logs()[0], entry, four[entry]) for entry in (KORTHAZZ, ZELIEK)}
    raid.stage([[f"targetnpc:{KORTHAZZ}", f"cmd:.modify hp {tops[KORTHAZZ] * 7 // 10} {tops[KORTHAZZ]}",
                 f"targetnpc:{ZELIEK}", f"cmd:.modify hp {tops[ZELIEK] * 11 // 20} {tops[ZELIEK]}"], [], []])
    wait_for("the two survivors hurt", lambda: all(health(raid.logs()[0], entry, four[entry]) < tops[entry]
                                                   for entry in (KORTHAZZ, ZELIEK)), 5)
    raid.slay_saved(BLAUMEUX, four[BLAUMEUX])
    host = raid.slay_saved(MOGRAINE, four[MOGRAINE])
    checkpointed = time.monotonic()
    spirits = {entry: wait_for(f"the spirit of {entry}", lambda: (lambda found: next(iter(found)) if len(found) == 1
                                                                   else None)(raid.seen(SPIRITS[entry])), 4)
               for entry in (BLAUMEUX, MOGRAINE)}
    hurt = {entry: health(raid.logs()[0], entry, four[entry]) for entry in (KORTHAZZ, ZELIEK)}
    # The crash comes before the survivors' second mark: each is due twelve seconds after the first.
    for entry in (KORTHAZZ, ZELIEK):
        assert raid.logs()[0].count(f"[spell go] {MARKS[entry]} by {four[entry]}") == 1, \
            f"horseman {entry} marked again before the crash"
    marks_on = {member: {spell for spell in MARKS.values()
                         if f"[player aura] {raid.guids[member]} received {spell}" in raid.logs()[member]}
                for member in range(2)}
    assert all(marks_on.values()), f"the members by the Horsemen were not marked: {marks_on}"
    assert door_state(raid.logs()[2]) == 1, "the door open during the fight"

    back, after = raid.crash(host)
    # `on`, not a toggle: the recovered sessions keep their GM toggles.
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    logs = after()
    for member, log in enumerate(logs[:2]):
        for entry in (BLAUMEUX, MOGRAINE):
            assert not creatures(log, entry), f"member {member}: the slain horseman {entry} is back"
            assert creatures(log, SPIRITS[entry]) == {spirits[entry]}, \
                f"member {member} sees spirits {creatures(log, SPIRITS[entry])} of {entry}, not {spirits[entry]}"
        for entry in (KORTHAZZ, ZELIEK):
            assert creatures(log, entry) == {four[entry]}, f"member {member} sees {entry} {creatures(log, entry)}"
            restored = health(log, entry, four[entry])
            assert abs(restored - hurt[entry]) * 100 <= tops[entry], \
                f"member {member} sees {entry} at {restored} health, before the crash {hurt[entry]} of {tops[entry]}"
        # The marks they bore come back with them, before any horseman marks again.
        first_mark = min((log.find(f"[spell go] {spell} ") for spell in MARKS.values()
                          if f"[spell go] {spell} " in log), default=len(log))
        kept = {spell for spell in marks_on[member]
                if f"[player aura] {raid.guids[member]} received {spell}" in log[:first_mark]}
        assert kept == marks_on[member], f"member {member} came back marked by {kept}, not {marks_on[member]}"
    assert door_state(logs[2]) in (None, 1), "the door opened after the crash"

    # The survivors mark on their saved timers (the outage not counted), not on a pull's twenty seconds.
    timing = {}
    for entry in (KORTHAZZ, ZELIEK):
        again = wait_for(f"horseman {entry} marking again", lambda: marked(after()[0], entry, four[entry]),
                         MARK_EVERY + 8) and time.monotonic()
        expected = back + MARK_EVERY - (checkpointed - first_marks[entry])
        timing[entry] = (again - back, expected - back)
        assert abs(again - expected) < 4, f"horseman {entry} marked {again - back:.1f} s after the recovery, not " \
                                          f"{expected - back:.1f} s: his timer did not continue"
    wait_for("the spirits marking on", lambda: all(marked(after()[0], entry, spirits[entry])
                                                   for entry in (BLAUMEUX, MOGRAINE)), FIRST_MARK + 6)

    raid.restart(host)  # three voters again: the next crash leaves a majority
    first = host
    raid.slay_saved(KORTHAZZ, four[KORTHAZZ])
    assert not any(objects(log, CHEST) for log in raid.logs()), "a chest with Zeliek alive"
    host = raid.slay_saved(ZELIEK, four[ZELIEK])
    chest = wait_for("the Four Horsemen's chest", lambda: (lambda found: found if found else None)(
        set().union(*(objects(log, CHEST) for log in raid.logs()))), 5)
    assert len(chest) == 1, f"chests {chest}"
    wait_for("the door open", lambda: door_state(raid.logs()[2]) == 0, 5)
    assert any(objects(log, PORTAL) for log in raid.logs()), "no portal of the quarter"

    _, since_death = raid.crash(host)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    time.sleep(3)
    logs = since_death()
    for member, log in enumerate(logs[:2]):
        assert objects(log, CHEST) == chest, f"member {member} sees chests {objects(log, CHEST)}, before {chest}"
        for entry in HORSEMEN:
            assert not creatures(log, entry), f"member {member}: horseman {entry} alive again"
    assert door_state(logs[2]) in (None, 0) and any(door_state(log) == 0 for log in logs), \
        "the door shut again after the crash"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {first} after two of the Four Horsemen fell and {host} after the last; the original clients "
          f"came back to raid copy {raid.copy} with the slain dead and their spirits {sorted(spirits.values())} "
          f"there and marking, Korth'azz and Zeliek at their health ({hurt[KORTHAZZ]}, {hurt[ZELIEK]}) and marking on "
          f"their timers ({', '.join(f'{a:.1f} s, expected {e:.1f}' for a, e in timing.values())}), the members' "
          f"marks kept and the door shut; slain, the four left one chest {sorted(chest)} "
          f"and the open door through a second crash")


def wipe(fixture):
    raid = Raid(fixture)
    four = raid.into_the_room()
    raid.pull(four)
    raid.slay(BLAUMEUX, MOGRAINE)
    wait_for("Blaumeux and Mograine slain", lambda: four[BLAUMEUX] not in raid.seen(BLAUMEUX)
             and four[MOGRAINE] not in raid.seen(MOGRAINE), 8)
    offsets = list(map(len, raid.logs()))
    since = lambda: [log[offset:] for log, offset in zip(raid.logs(), offsets)]
    before = raid.checkpoints()
    # The raid dies; each comes back to life at once, away from the room.
    raid.stage([["cmd:.cheat god off", "wait:1", *(f"cmd:.killplr {name}" for name in raid.names), "wait:1",
                 "targetplayer:0", "cmd:.revive", port(BY_DOOR)],
                ["cmd:.cheat god off", "wait:2", "cmd:.revive", port(BY_DOOR)],
                ["cmd:.cheat god off", "wait:2", "cmd:.revive"]])
    wait_for("the slain back after the wipe", lambda: all(four[entry] in creatures(since()[2], entry)
                                                         for entry in (BLAUMEUX, MOGRAINE)), 40)
    wait_for("the door open after the wipe", lambda: door_state(raid.logs()[2]) == 0, 20)
    host = raid.next_checkpoint(before, "the checkpoint of the wipe", 10)

    _, after = raid.crash(host)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    time.sleep(3)
    logs = after()
    for member, log in enumerate(logs):
        for entry in HORSEMEN:
            assert creatures(log, entry) == {four[entry]}, \
                f"member {member} sees horseman {entry} {creatures(log, entry)}, not {four[entry]}"
        for spirit in SPIRITS.values():
            assert not creatures(log, spirit), f"member {member}: spirit {spirit} after the wipe"
    assert door_state(logs[2]) == 0, "the door shut after the crash"

    raid.restart(host)
    raid.pull(four)
    offsets = list(map(len, raid.logs()))
    raid.slay(*HORSEMEN)
    wait_for("the four slain again", lambda: all(died(raid.logs()[0][offsets[0]:], entry, four[entry])
                                                 for entry in HORSEMEN), 10)
    chest = wait_for("the Four Horsemen's chest", lambda: (lambda found: found if found else None)(
        set().union(*(objects(log, CHEST) for log in raid.logs()))), 5)
    assert len(chest) == 1, f"chests {chest}"
    wait_for("the door open", lambda: door_state(raid.logs()[2]) == 0, 5)
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} after a wipe that followed two of the Four Horsemen's deaths; the original clients "
          f"came back to raid copy {raid.copy} with the four alive at home, no spirit and the door open; pulled "
          f"again and slain, they left one chest {sorted(chest)}")


PHASES = {"kills": kills, "wipe": wipe}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=PHASES, required=True)
    args = parser.parse_args()
    run_test(f"horsemen-{args.phase}-recovery", PHASES[args.phase])
