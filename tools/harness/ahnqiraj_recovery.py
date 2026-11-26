#!/usr/bin/env python3
"""Kill the Ahn'Qiraj raids' worker in the Bug Trio's or the Twin Emperors' fight (the Temple), or in the army's waves
(the Ruins), and resume it in the same raid copy on the same sockets.

Three scripted raid members (GMs, on a gateway) stand by the bosses.

    --phase army   in the Ruins, the leader slays Kurinnaxx; General Andorov comes with his four Kaldorei and walks to
                   the gates, where the leader asks him to lead the attack, and the army's waves charge the raid where
                   he fights. The first two waves beaten, the worker dies in the third, Captain Drenn's. All three
                   original sockets come back to the same copy with the same Andorov where he fights and the same
                   Kaldorei. Drenn, never struck (the members do not fight back), had no snapshot of a hurt creature
                   and comes back home: his wave, the one under way, charges once more. The next four follow, none
                   of the first two again, and Rajaxx last; slain, Andorov trades.
                   Not in chaos.py: before any crash, Andorov now and then keeps fighting the member who
                   asked him and never starts the army (an open fault, docs/ROADMAP.md).

    --phase trio   each member takes on one of Lord Kri, Princess Yauj and Vem; Kri is brought down and devoured, and
                   the worker dies just after the checkpoint of it. All three original sockets come back to the same
                   copy with the same Yauj and Vem and no Kri. Vem brought down is devoured, and Yauj, the last, dies.
                   The worker that took over dies just after the checkpoint of her death: none of the three is back.
    --phase twins  the leader has slain Princess Huhuran, so the door to the emperors opens, and watches it; the two
                   others pull Vek'nilash and Vek'lor, and the worker dies just after the checkpoint of the pull. The
                   same emperors come back fighting, with the door shut and no snapshot of a hurt creature of them.
                   Slain, both die and the doors in and out open.

Ouro's fight has no case: his sand is untouchable and wakes only when struck, so no client can begin it (the real-data
tests in source/dmangos/world/realscripts_raids.d strike it, and cover his crash).
"""

import argparse
import re
import time

from cluster_fixture import WORLD, run_test, wait_for
from cthun_recovery import creatures, unit_guid
from dungeon_recovery import open_party, start_cluster
from kelthuzad_recovery import door_state
from sapphiron_recovery import kill_host


TEMPLE = 531
KRI, YAUJ, VEM = 15511, 15543, 15544
VEKLOR, VEKNILASH, HUHURAN = 15276, 15275, 15509
DOOR_IN, DOOR_OUT, BY_THE_DOOR_IN = 180634, 180635, (-8922.0, 1352.0, -104.2)

RUINS = 509
KURINNAXX, ANDOROV, KALDOREI, RAJAXX = 15348, 15471, 15473, 15341
CAPTAINS = (15391, 15392, 15389, 15390, 15386, 15388, 15385)  # the waves' captains, in order
WARRIOR, NEEDLER = 15387, 15344
GATE_TRASH = (15325, 15327, 15461, 15462)  # the wasps, stingers and scarabs about the gates and his place
GATES, FIGHT = (-8876.97, 1651.96, 21.57), (-8940.45, 1550.69, 21.62)  # where Andorov waits, and fights
ANDOROV_INTRO = "Remember, Rajaxx, when I said I'd kill you last?"
THIRD_WAVE_YELL, RAJAXX_INTRO = "The time of our retribution is at hand!", "Impudent fool! I will kill you myself!"


class Raid:
    """Three raid members in a copy of `map_id`, the leader at `at`, driven stage by stage."""

    def __init__(self, fixture, map_id, at):
        self.fixture, self.map = fixture, map_id
        characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=False, raid=True,
                                                                     extra_member=True)
        self.characters, self.nodes = characters, nodes
        self.next = [fixture.directory / f"stage-0-{member}" for member in range(3)]
        actions = [(f"waitactions:{self.next[member]}",) for member in range(3)]
        self.copy, self.logs, self.clients = open_party(fixture, characters, names, leader, client, nodes, False,
                                                        actions, map_id=map_id, entrance=self.port(at))
        self.number = 0

    def port(self, at):
        return f"worldport:{self.map}:" + ":".join(f"{v:.2f}" for v in at)

    def stage(self, actions):
        """Each member's next actions (a list per member), written at once; each waits for its next stage after."""
        self.number += 1
        for member in range(3):
            following = self.fixture.directory / f"stage-{self.number}-{member}"
            self.next[member].write_text("\n".join([*actions[member], f"waitactions:{following}"]) + "\n")
            self.next[member] = following

    def finish(self):
        for path in self.next:
            path.write_text("logout\n")
        for i, process in enumerate(self.clients):
            if process.wait(timeout=30):
                raise RuntimeError(self.logs()[i][-4000:])

    def checkpoints(self):
        line = f"instance {self.copy} of map {self.map} saved an encounter checkpoint"
        return {tag: self.fixture.log(tag).count(line) for tag in self.nodes}

    def next_checkpoint(self, before, why, seconds):
        def newer():
            return next((tag for tag, count in self.checkpoints().items() if count > before.get(tag, 0)), None)
        return wait_for(why, newer, seconds)

    def same_copy(self):
        query = self.fixture.query
        assert query(f"SELECT id FROM instance WHERE map={self.map}", self.characters) == str(self.copy), \
            "a second raid copy"
        assert query(f"SELECT COUNT(*) FROM character_instance WHERE instance={self.copy}", self.characters) == "3"

    def crash(self, host, expect=None):
        """Kills `host` and waits for the three original sockets to come back to the copy; their logs since."""
        offsets = list(map(len, self.logs()))
        kill_host(self.nodes, host)

        def since():
            return [log[offset:] for log, offset in zip(self.logs(), offsets)]

        wait_for("the three original sockets back in the copy", lambda: all(
            f"[new world] map {self.map} " in part and (expect is None or expect(part)) for part in since()), 60)
        self.same_copy()
        # The recovered sessions keep their GM toggles: `on`, not a toggle, keeps them immune.
        self.stage([["cmd:.cheat god on"] for _ in range(3)])
        return since

    def restart(self, host):
        """Starts the killed `host` again (a new incarnation, its own log), and waits for it to hold a lease."""
        again = f"{host}-again"
        self.nodes[again] = self.fixture.start(again, [WORLD, "-c", self.fixture.directory / f"{host}.json"])
        wait_for(f"{host} back in the cluster", lambda: "lease holds" in self.fixture.log(again), 45)

    def native_fights(self, spawns):
        return int(self.fixture.query(f"SELECT COUNT(*) FROM dmangos_dungeon_fight WHERE spawn IN "
                                      f"({','.join(map(str, spawns))})", self.characters))


def spawn_of(fixture, entry, map_id=TEMPLE):
    """The spawn guid and position of `entry` on `map_id` (the temple's)."""
    guid, x, y, z = fixture.query(f"SELECT guid,position_x,position_y,position_z FROM creature WHERE map={map_id} "
                                  f"AND id={entry} ORDER BY guid LIMIT 1", fixture.base["world_database"]).split()
    return int(guid), (float(x), float(y), float(z))


def beside(at, yards=3.0):
    return (at[0] + yards, at[1], at[2])


def seen(logs, entry, living=True):
    return set().union(*(creatures(log, entry, living) for log in logs))


def slain(log, entry, spawn):
    return re.search(rf"\[changes\] {unit_guid(entry, spawn)}: fields .*?health 0/", log) is not None


def gone(log, entry, spawn):
    """Whether `log` shows the creature not there now: never shown, or taken away after it was last shown."""
    shown = f"[creature] {entry} guid {spawn}:"
    if shown not in log:
        return True
    rest = log.rsplit(shown, 1)[1]
    full = unit_guid(entry, spawn)
    return f"[destroyed] {full}" in rest or re.search(rf"\[out of range\] .*\b{full & 0xFFFFFFFF}\b", rest) is not None


def trio(fixture):
    kri, kri_at = spawn_of(fixture, KRI)
    yauj, yauj_at = spawn_of(fixture, YAUJ)
    vem, vem_at = spawn_of(fixture, VEM)
    raid = Raid(fixture, TEMPLE, beside(kri_at))
    raid.stage([[], [raid.port(beside(yauj_at))], [raid.port(beside(vem_at))]])
    wait_for("the Bug Trio in sight", lambda: all(seen(raid.logs(), entry) == {spawn} for entry, spawn in
                                                  ((KRI, kri), (YAUJ, yauj), (VEM, vem))), 15)
    # They see the raid come (the pull's checkpoint may be behind already): each member takes one on.
    raid.stage([[f"attack:{KRI}"], [f"attack:{YAUJ}"], [f"attack:{VEM}"]])
    wait_for("the three fighting", lambda: all(any(f"[attack start] {spawn} -> " in log for log in raid.logs())
                                               for spawn in (kri, yauj, vem)), 10)
    time.sleep(1)
    before = raid.checkpoints()
    raid.stage([[f"killpack:one:{KRI}"], [], []])
    host = raid.next_checkpoint(before, "the checkpoint of Kri devoured", 10)
    assert not any(slain(log, KRI, kri) for log in raid.logs()), "Kri died: he must be devoured"
    since = raid.crash(host, lambda part: f"[creature] {YAUJ} guid {yauj}:" in part
                       and f"[creature] {VEM} guid {vem}:" in part)
    time.sleep(4)  # Kri, back with his cell, goes again at once
    for member, log in enumerate(since()):
        assert seen([log], YAUJ) == {yauj} and seen([log], VEM) == {vem}, f"member {member}: another Yauj or Vem"
        assert gone(log, KRI, kri), f"member {member}: the devoured Kri back after the crash"

    before = raid.checkpoints()
    raid.stage([[], [], [f"killpack:one:{VEM}"]])
    raid.next_checkpoint(before, "the checkpoint of Vem devoured", 10)
    wait_for("Vem gone, devoured", lambda: all(gone(log, VEM, vem) for log in since()), 8)
    assert not any(slain(log, VEM, vem) for log in since()), "Vem died: he must be devoured"
    raid.restart(host)  # three voters again: the next crash leaves a majority
    first = host
    before = raid.checkpoints()
    raid.stage([[], [f"killpack:one:{YAUJ}"], []])
    wait_for("Yauj, the last, slain", lambda: any(slain(log, YAUJ, yauj) for log in since()), 8)
    host = raid.next_checkpoint(before, "the checkpoint of Yauj's death", 5)
    after = raid.crash(host, lambda part: f"[creature] {YAUJ} guid {yauj}:" in part)
    time.sleep(4)
    for member, log in enumerate(after()):
        assert not seen([log], YAUJ), f"member {member}: Yauj alive after the trio's end"
        for entry, spawn in ((KRI, kri), (VEM, vem)):  # their cells bring the devoured back: they go again at once
            assert gone(log, entry, spawn), f"member {member}: the devoured {entry} back after the trio's end"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {first} with Kri devoured; the original clients came back to raid copy {raid.copy} with the "
          f"same Yauj {yauj} and Vem {vem} and no Kri; Vem was devoured and Yauj, the last, died; killed {host} after "
          f"her death and none of the three came back")


def twins(fixture):
    veknilash, nilash_at = spawn_of(fixture, VEKNILASH)
    veklor, lor_at = spawn_of(fixture, VEKLOR)
    _, huhuran_at = spawn_of(fixture, HUHURAN)
    raid = Raid(fixture, TEMPLE, beside(huhuran_at, 8))
    wait_for("Princess Huhuran in sight", lambda: seen(raid.logs()[:1], HUHURAN), 15)
    raid.stage([[f"killpack:{HUHURAN}", raid.port(BY_THE_DOOR_IN)], [raid.port(beside(nilash_at, 30))],
                [raid.port(beside(lor_at, 30))]])
    wait_for("the door in open, Huhuran slain", lambda: door_state(raid.logs()[0], DOOR_IN) == 0, 20)
    wait_for("the emperors in sight", lambda: seen(raid.logs()[1:2], VEKNILASH) == {veknilash}
             and seen(raid.logs()[2:], VEKLOR) == {veklor}, 15)
    before = raid.checkpoints()
    raid.stage([[], [f"attack:{VEKNILASH}"], [f"attack:{VEKLOR}"]])
    host = raid.next_checkpoint(before, "the checkpoint of the emperors' pull", 10)
    assert door_state(raid.logs()[0], DOOR_IN) == 1, "the door in open in their fight"
    since = raid.crash(host)
    wait_for("each emperor in sight of the member who pulled him", lambda: (lambda logs: f"[creature] {VEKNILASH} "
             f"guid {veknilash}:" in logs[1] and f"[creature] {VEKLOR} guid {veklor}:" in logs[2])(since()), 15)
    # Back from the encounter's checkpoint: the one not fighting yet when it was written joins as the raid returns.
    # (Every player in the copy joins their fight, the one by the door too: each goes after whom he will.)
    def acting(entry, spawn, log):
        return re.search(rf"\[swing\] {spawn} -> |\[spell (go|start)\] \d+ by {spawn}\b|\[monster moves\] {entry} guid "
                         rf"{spawn}:", log) is not None
    for entry, spawn in ((VEKNILASH, veknilash), (VEKLOR, veklor)):
        wait_for(f"emperor {spawn} fighting after the crash", lambda: any(acting(entry, spawn, log)
                                                                         for log in since()), 20)
    logs = since()
    assert seen(logs, VEKNILASH) == {veknilash} and seen(logs, VEKLOR) == {veklor}, "another emperor"
    assert door_state(logs[0], DOOR_IN) == 1, "the door in open after the crash, in their fight"
    assert raid.native_fights((veknilash, veklor)) == 0, "the encounter's own checkpoint owns the emperors"
    raid.stage([[], [f"killpack:{VEKNILASH}"], []])
    wait_for("both emperors slain", lambda: all(any(slain(log, entry, spawn) for log in since())
                                                for entry, spawn in ((VEKNILASH, veknilash), (VEKLOR, veklor))), 10)
    wait_for("the doors in and out open", lambda: door_state(since()[0], DOOR_IN) == 0
             and door_state(since()[0], DOOR_OUT) == 0, 6)
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} just after the emperors' pull; the original clients came back to raid copy "
          f"{raid.copy} with the same emperors fighting and the door in shut; slain, both died and the doors opened")


def said(logs, text):
    """Whether a creature's line beginning with `text` reached one of `logs`."""
    return any(f": '{text}" in log for log in logs)


def fighting(logs, spawn):
    return any(re.search(rf"\[(attack start|swing)\] {spawn} -> ", log) for log in logs)


def slay(raid, logs, captain, spawn):
    """The member who sees `captain` slays him and the army in his sight (the others may not see him)."""
    slayer = next((member for member, log in enumerate(logs) if spawn in seen([log], captain)), 0)
    raid.stage([[f"killpack:{captain}:{WARRIOR}:{NEEDLER}"] if member == slayer else [] for member in range(3)])


def army(fixture):
    _, kurinnaxx_at = spawn_of(fixture, KURINNAXX, RUINS)
    raid = Raid(fixture, RUINS, beside(kurinnaxx_at))
    wait_for("Kurinnaxx in sight", lambda: seen(raid.logs()[:1], KURINNAXX), 15)
    kurinnaxx = next(iter(seen(raid.logs()[:1], KURINNAXX)))
    raid.stage([[f"killpack:{KURINNAXX}"], [], []])
    wait_for("Kurinnaxx slain", lambda: slain(raid.logs()[0], KURINNAXX, kurinnaxx), 10)
    # General Andorov comes where Kurinnaxx's death calls him, out of sight, and walks to the gates.
    raid.stage([[raid.port(GATES)] for _ in range(3)])
    andorov = wait_for("General Andorov", lambda: next(iter(seen(raid.logs(), ANDOROV)), None), 150)
    full = unit_guid(ANDOROV, andorov)
    # At the gates he waits to be asked (his gossip flag): asked, he speaks and leads the attack.
    wait_for("Andorov waiting at the gates", lambda: re.search(
        rf"\[changes\] {full}: fields \[[^\]]*\b147\b|\[creature\] {ANDOROV} guid {andorov}: .*npc flags 1,",
        raid.logs()[0]), 150)
    # The trash about the gates cleared first: Andorov stops for every fight on his way.
    # (He turns on the one who asks him, and now and then never reaches his place: an open fault, not a crash's.)
    trash = "killpack:any:" + ":".join(map(str, GATE_TRASH))
    raid.stage([[trash], [trash], [raid.port(FIGHT), "wait:3", trash]])
    time.sleep(8)
    raid.stage([[], [f"npc:{ANDOROV}", "gossip", "select:0"], []])
    wait_for("Andorov's words", lambda: said(raid.logs(), ANDOROV_INTRO), 10)
    raid.stage([[raid.port(FIGHT)] for _ in range(3)])  # with him where he fights: the army charges the raid there
    kaldorei = wait_for("his four Kaldorei", lambda: (lambda elites: elites if len(elites) == 4 else None)(
        seen(raid.logs(), KALDOREI)), 20)

    def beat(captain, logs):
        """The wave of `captain` charging, it and the army in sight are slain."""
        spawn = wait_for(f"captain {captain} charging", lambda: next(
            (s for s in seen(logs(), captain) if fighting(logs(), s)), None), 90)
        slay(raid, logs(), captain, spawn)
        wait_for(f"captain {captain} slain", lambda: any(slain(log, captain, spawn) for log in logs()), 15)

    for captain in CAPTAINS[:2]:
        beat(captain, raid.logs)
    time.sleep(1)  # the checkpoint of the second captain's death behind
    # The second wave beaten, the third comes at the next look, saved as it does.
    host = raid.next_checkpoint(raid.checkpoints(), "the checkpoint of the third wave's charge", 10)
    drenn = wait_for("Captain Drenn charging, the third wave", lambda: next(
        (s for s in seen(raid.logs(), CAPTAINS[2]) if fighting(raid.logs(), s)), None), 60)
    wait_for("Rajaxx's yell at the third wave", lambda: said(raid.logs(), THIRD_WAVE_YELL), 5)
    since = raid.crash(host, lambda part: f"[creature] {ANDOROV} guid {andorov}:" in part)
    logs = since()
    assert seen(logs, ANDOROV) == {andorov}, f"Andorovs after the crash: {seen(logs, ANDOROV, living=False)}"
    at = re.findall(rf"\[creature\] {ANDOROV} guid {andorov}: .*? at (\S+) (\S+) (\S+)", logs[0])[-1]
    assert distance(tuple(map(float, at)), FIGHT) < 25, f"Andorov back at {at}, not where he fights"
    assert seen(logs, KALDOREI) == kaldorei, f"Kaldorei after the crash {seen(logs, KALDOREI)}, before {kaldorei}"
    # The members do not strike (a GM's client cannot face a captain it sees only where he was), so Drenn, never hurt,
    # had no snapshot of a hurt creature: he comes back home, and his wave, the one under way, charges again.
    wait_for("Captain Drenn fighting", lambda: seen(since(), CAPTAINS[2]) == {drenn} and fighting(since(), drenn), 20)
    slay(raid, since(), CAPTAINS[2], drenn)
    wait_for("Captain Drenn slain", lambda: any(slain(log, CAPTAINS[2], drenn) for log in since()), 15)
    # The next waves, to Rajaxx: each captain who charges is slain (one whose cell no member's sight loads charges
    # with no one, and the next follows).
    def rajaxx_fighting():
        return next((s for s in seen(since(), RAJAXX) if fighting(since(), s)), None)

    deadline = time.monotonic() + 300
    staged = time.monotonic()
    while not rajaxx_fighting():
        assert time.monotonic() < deadline, "Rajaxx never came after the crash"
        for captain in CAPTAINS[3:]:
            spawn = next((s for s in seen(since(), captain) if fighting(since(), s)), None)
            if spawn is not None:
                slay(raid, since(), captain, spawn)
                staged = time.monotonic()
                wait_for(f"captain {captain} slain", lambda: any(slain(log, captain, spawn) for log in since()), 15)
        if time.monotonic() - staged > 60:  # the clients wait for their next stage a while only
            raid.stage([["cmd:.cheat god on"] for _ in range(3)])  # (and the gateway drops a client silent 240 s)
            staged = time.monotonic()
        time.sleep(1)
    for member, log in enumerate(since()):
        assert log.count(f": '{THIRD_WAVE_YELL}") <= 1, f"member {member}: the third wave came more than once again"
    for captain in CAPTAINS[:2]:
        assert not seen(since(), captain), f"captain {captain}, beaten, back after the crash"
    rajaxx = wait_for("Rajaxx himself", lambda: next((s for s in seen(since(), RAJAXX) if fighting(since(), s)), None),
                      60)
    assert said(since(), RAJAXX_INTRO), "Rajaxx's line as he comes"
    slayer = next(member for member, log in enumerate(since()) if rajaxx in seen([log], RAJAXX))
    raid.stage([[f"killpack:{RAJAXX}"] if member == slayer else [] for member in range(3)])
    wait_for("Rajaxx slain", lambda: any(slain(log, RAJAXX, rajaxx) for log in since()), 15)
    # The army beaten, the same Andorov trades (his flags change).
    wait_for("Andorov trading", lambda: len(re.findall(rf"\[changes\] {full}: fields \[[^\]]*\b147\b",
                                                       since()[0])) > 0, 10)
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} in the army's third wave; the original clients came back to raid copy {raid.copy} "
          f"with the same Andorov {andorov} where he fights and his four Kaldorei; Captain Drenn's wave, the one under "
          f"way, charged once more and the next four followed it, none of the first two again; Rajaxx came, fell, "
          f"and Andorov traded")


def distance(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


PHASES = {"trio": trio, "twins": twins, "army": army}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=sorted(PHASES), required=True)
    args = parser.parse_args()
    run_test(f"aq{20 if args.phase == 'army' else 40}-{args.phase}-recovery", PHASES[args.phase])
