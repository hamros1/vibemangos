#!/usr/bin/env python3
"""Kill the Naxxramas worker during Sapphiron's fight and resume it in the same raid copy on the same sockets.

Three scripted raid members (GMs, on a gateway) walk into the Frostwyrm Lair; its birth springs and Sapphiron comes
22 seconds later.

    --phase air     the worker dies after Sapphiron's Icebolt froze one member (the others stood within ten yards of
                    him, so no other is frozen), one hides behind the ice block and one stands in the open, and before
                    Frost Breath begins. All three original sockets come back to the same copy with the same
                    Sapphiron in the air, the same single ice block and the member still frozen; the breath begins on
                    the saved timer and lands once: it strikes the member in the open, not the one behind the block.
                    He lands and the block melts.
    --phase ground  the worker dies in the ground phase with Sapphiron hurt: he comes back with his health and Frost
                    Aura, rises on his first timer, breathes once and lands. Slain, he opens the waterfall to
                    Kel'Thuzad; the worker dies again, and the waterfall is open and Sapphiron dead after recovery.
    --phase birth   the worker dies between the birth and Sapphiron's coming: he comes once, on the birth's timer.
"""

import argparse
import math
import re
import signal
import time

from cluster_fixture import WORLD, run_test, wait_for
from dungeon_recovery import open_party, start_cluster, wait


MAP = 533
SAPPHIRON, ICE_BLOCK, WATERFALL = 15989, 181247, 181225
FROST_AURA, LIFE_DRAIN, BLIZZARD, DRAGON_HOVER = 28529, 28542, 28560, 18430
ICEBOLT, ICEBOLT_IMMUNITY, FROST_BREATH, FROST_BREATH_TRIGGERED = 28522, 31800, 28524, 29318
LAIR = (3521.48, -5225.87, 137.626)
HOVER = (3522.386, -5236.784, 137.709)
RISE_AFTER, BREATH_AFTER_RISE, COMES_AFTER_BIRTH = 46, 23, 22
ATTUNEMENT = 9378


def checkpoints(fixture, nodes, copy):
    line = f"instance {copy} of map {MAP} saved an encounter checkpoint"
    return {tag: fixture.log(tag).count(line) for tag in nodes}


def newer_checkpoint(fixture, nodes, copy, before):
    return next((tag for tag, count in checkpoints(fixture, nodes, copy).items() if count > before[tag]), None)


def kill_host(nodes, host):
    nodes[host].send_signal(signal.SIGKILL)
    assert nodes[host].wait(timeout=10) == -signal.SIGKILL


def sapphirons(log, living=True):
    """The Sapphirons (spawn guids) the client was shown, alive unless `living` is False."""
    shown = {int(guid): int(health) for guid, health in
             re.findall(rf"\[creature\] {SAPPHIRON} guid (\d+): .*?health (\d+),", log)}
    dead = {int(guid) & 0xFFFFFF for guid in re.findall(r"\[changes\] (\d+): fields .*?health 0/", log)}
    return {guid for guid, health in shown.items() if not living or (health > 0 and guid not in dead)}


def unit_hex(spawn):
    return f"{(0xF130 << 48) | (SAPPHIRON << 24) | spawn:#018x}"


def hovering(log, spawn):
    """Whether Sapphiron's last Dragon Hover aura change in `log` gave it to him."""
    changes = re.findall(rf"\[creature aura\] {unit_hex(spawn)} (received|ended) {DRAGON_HOVER}\b", log)
    return bool(changes) and changes[-1] == "received"


def ice_blocks(log):
    return set(map(int, re.findall(rf"\[game object\] {ICE_BLOCK} guid (\d+):", log)))


def waterfall_state(log):
    """The waterfall's last state the client was told (0 open, 1 shut), or None."""
    created = re.findall(rf"\[game object\] {WATERFALL} guid (\d+): .*?state (\d+)", log)
    if not created:
        return None
    guid, state = int(created[-1][0]), created[-1][1]
    rest = log.rsplit(f"[game object] {WATERFALL} guid {guid}:", 1)[1]
    for full, changed in re.findall(r"\[game object state\] (0x[0-9a-f]+) state (\d+)", rest):
        if int(full, 16) & 0xFFFFFF == guid:
            state = changed
    return int(state)


class Raid:
    """Three raid members in Sapphiron's lair (or at `at` in Naxxramas, the leader `leader_appearance`'s race and
    class), driven stage by stage."""

    def __init__(self, fixture, at=None, leader_appearance=(1, 1)):
        self.fixture = fixture
        characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=False, raid=True,
                                                                     extra_member=True,
                                                                     leader_appearance=leader_appearance)
        self.characters, self.names, self.nodes = characters, names, nodes
        self.guids = [int(fixture.query(f"SELECT guid FROM characters WHERE name='{name}'", characters))
                      for name in names]
        # Attuned to Naxxramas (The Dread Citadel - Naxxramas, the entrance's quest).
        fixture.query("INSERT INTO character_queststatus (guid, quest, status, rewarded) VALUES "
                      + ",".join(f"({guid},{ATTUNEMENT},1,1)" for guid in self.guids), characters)
        entrance = f"worldport:{MAP}:" + ":".join(map(str, at or LAIR))
        first = [fixture.directory / f"stage-0-{member}" for member in range(3)]
        # A step into the lair springs the birth's trap.
        step = () if at else (f"move:{LAIR[0] + 0.5}:{LAIR[1] - 1}:{LAIR[2]}",)
        actions = [(*step, f"waitactions:{first[member]}") for member in range(3)]
        self.copy, self.logs, self.clients = open_party(fixture, characters, names, leader, client, nodes, False,
                                                        actions, map_id=MAP, entrance=entrance)
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

    def sapphiron(self, seconds):
        """Sapphiron's spawn guid, once one client sees him."""
        return wait_for("Sapphiron", lambda: next(iter(set().union(*map(sapphirons, self.logs()))), None), seconds)

    def crash(self, host, expect=None):
        """Kills `host` and waits for the three original sockets to come back to the copy; their logs since."""
        offsets = list(map(len, self.logs()))
        killed = time.monotonic()
        kill_host(self.nodes, host)

        def recovered():
            parts = [log[offset:] for log, offset in zip(self.logs(), offsets)]
            if all(f"[new world] map {MAP} " in part and (expect is None or expect(part)) for part in parts):
                return parts

        wait_for("the three original sockets back in the copy", recovered, 60)
        self.same_copy()
        return killed, time.monotonic(), lambda: [log[offset:] for log, offset in zip(self.logs(), offsets)]

    def restart(self, host):
        """Starts the killed `host` again (a new incarnation, its own log), and waits for it to hold a lease."""
        again = f"{host}-again"
        self.nodes[again] = self.fixture.start(again, [WORLD, "-c", self.fixture.directory / f"{host}.json"])
        wait_for(f"{host} back in the cluster", lambda: "lease holds" in self.fixture.log(again), 45)


def air(fixture):
    raid = Raid(fixture)
    sap = raid.sapphiron(COMES_AFTER_BIRTH + 8)
    rise = wait_for("Sapphiron to take to the air", lambda: any(hovering(log, sap) for log in raid.logs()),
                    RISE_AFTER + 10) and time.monotonic()
    # Within ten yards of each other: his first Icebolt freezes one, and the next ones find nobody to freeze.
    spots = [(HOVER[0] + 10, HOVER[1] + (member - 1) * 3, HOVER[2]) for member in range(3)]
    raid.stage([[f"worldport:{MAP}:{x}:{y}:{z}"] for x, y, z in spots])

    def frozen_member():
        for log in raid.logs():
            for member, guid in enumerate(raid.guids):
                if f"[player aura] {guid} received {ICEBOLT}" in log:
                    return member + 1

    frozen = wait_for("a member frozen by his Icebolt", frozen_member, 14) - 1
    block = wait_for("the ice block", lambda: (lambda seen: seen if len(seen) == 1 else None)(
        set().union(*map(ice_blocks, raid.logs()))), 4)
    hider, exposed = [member for member in range(3) if member != frozen]
    bx, by, bz = spots[frozen]
    dx, dy = bx - HOVER[0], by - HOVER[1]
    length = math.hypot(dx, dy)
    behind = (bx + 5 * dx / length, by + 5 * dy / length, bz)
    exposed_spot = (behind[0], behind[1] + 12, bz)
    moves = [[] for _ in range(3)]
    moves[hider] = [f"worldport:{MAP}:{behind[0]:.3f}:{behind[1]:.3f}:{behind[2]}"]
    moves[exposed] = [f"worldport:{MAP}:{exposed_spot[0]:.3f}:{exposed_spot[1]:.3f}:{exposed_spot[2]}"]
    before = raid.checkpoints()
    raid.stage(moves)
    for member, (x, y, z) in ((hider, behind), (exposed, exposed_spot)):
        wait_for(f"member {member} in place", lambda: f"[teleport] to {x:.1f} {y:.1f} {z:.1f};"
                 in raid.logs()[member], 6)
    # The moves are saved with the encounter's next checkpoint (each Icebolt step makes one).
    before = raid.checkpoints()
    host = raid.next_checkpoint(before, "the checkpoint after the members took their places", 5)
    checkpointed = time.monotonic()
    assert not any(f"[spell start] {FROST_BREATH} " in log or f"[spell go] {FROST_BREATH} " in log
                   for log in raid.logs()), "the crash must come before the breath"
    assert ":summons1:" in fixture.query(f"SELECT data FROM instance WHERE id={raid.copy}", raid.characters)

    killed, back, after = raid.crash(host, lambda part: f"[creature] {SAPPHIRON} guid {sap}:" in part)
    # The recovered sessions keep their GM toggles (`dmangos_gm_session`): `on`, not a toggle, keeps the frozen
    # member and the one behind the block immune to the Frost Aura, so that they live to the breath; the one in the
    # open is made mortal, with health enough to take it.
    cheats = [["cmd:.cheat god on"] for _ in range(3)]
    cheats[exposed] = ["cmd:.cheat god off", "cmd:.modify hp 400000"]
    raid.stage(cheats)
    logs = after()
    for member, log in enumerate(logs):
        assert sapphirons(log) == {sap}, f"member {member} sees Sapphirons {sapphirons(log)}, not {sap}"
        assert hovering(log, sap), f"member {member}: Sapphiron not back in the air"
        assert ice_blocks(log) == block, f"member {member} sees ice blocks {ice_blocks(log)}, before the crash {block}"
    assert f"[player aura] {raid.guids[frozen]} received {ICEBOLT}" in logs[frozen] \
        and f"[player aura] {raid.guids[frozen]} received {ICEBOLT_IMMUNITY}" in logs[frozen], \
        "the frozen member came back thawed"
    assert f"[player aura] {raid.guids[frozen]} received {ICEBOLT}" in logs[hider], \
        "the member behind the block does not see the other frozen"

    # The breath begins on the saved timer (the outage not counted) and lands once.
    begun = wait_for("Frost Breath begun after the crash", lambda: any(
        f"[spell start] {FROST_BREATH} by {sap}" in log for log in after()), BREATH_AFTER_RISE + 8) and time.monotonic()
    expected = back + BREATH_AFTER_RISE - (checkpointed - rise)
    assert abs(begun - expected) < 4, f"the breath began {begun - back:.1f} s after the recovery, not " \
                                      f"{expected - back:.1f} s: its timer did not continue"
    wait_for("Frost Breath landed", lambda: all(f"[spell go] {FROST_BREATH} by {sap}" in log for log in after()), 10)
    wait_for("Sapphiron landing", lambda: all(not hovering(log, sap) for log in after()), 4)
    logs = after()
    hits = {member: [int(amount) for amount in re.findall(
        rf"\[spell damage\] (?:{FROST_BREATH}|{FROST_BREATH_TRIGGERED}): (\d+) to {raid.guids[member]}\b",
        "\n".join(logs))] for member in range(3)}
    assert hits[exposed] and max(hits[exposed]) > 50_000, f"the member in the open was not struck: {hits}"
    assert not hits[hider], f"the breath struck the member behind the ice block: {hits}"
    assert not hits[frozen] or max(hits[frozen]) == 0, f"the breath struck the frozen member: {hits}"
    for member, log in enumerate(logs):
        assert log.count(f"[spell go] {FROST_BREATH} by {sap}") == 1, f"member {member}: the breath landed " \
                                                                      f"{log.count(f'[spell go] {FROST_BREATH} by {sap}')} times"
    gone = re.findall(r"\[destroyed\] (\d+)", "\n".join(logs)) + re.findall(r"\[out of range\] ([\d, ]+)", "\n".join(logs))
    melted = {int(guid) & 0xFFFFFF for entry in gone for guid in entry.split(", ")}
    assert block <= melted, f"the ice block {block} did not melt as he landed"
    assert f"[player aura] {raid.guids[frozen]} ended {ICEBOLT}" in logs[frozen], "still frozen after he landed"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} with member {frozen} frozen and before Frost Breath; all three original clients came "
          f"back to raid copy {raid.copy} with the same Sapphiron {sap} in the air, the same ice block {sorted(block)} "
          f"and the member frozen; the breath began {begun - back:.1f} s after recovery (expected "
          f"{expected - back:.1f}), landed once, struck the member in the open ({max(hits[exposed])}) and passed over "
          f"the one behind the block; he landed and the block melted")


def ground(fixture):
    raid = Raid(fixture)
    sap = raid.sapphiron(COMES_AFTER_BIRTH + 8)
    engaged = time.monotonic()
    top = int(re.findall(rf"\[creature\] {SAPPHIRON} guid {sap}: .*?health (\d+),", raid.logs()[0])[-1])
    # The leader (a GM) hurts him to 80%: an ungeared level 60 warrior hardly touches him.
    raid.stage([[f"targetnpc:{SAPPHIRON}", f"cmd:.modify hp {top * 4 // 5} {top}"], [], []])
    wait_for("Life Drain and a blizzard", lambda: all(f"[spell go] {spell} by {sap}" in raid.logs()[0]
                                                      for spell in (LIFE_DRAIN, BLIZZARD)), 20)
    host = raid.next_checkpoint(raid.checkpoints(), "a checkpoint of the ground phase", 12)
    checkpointed = time.monotonic()
    assert checkpointed - engaged < RISE_AFTER - 8, "too late for the ground phase"

    def health(log):
        shown = re.findall(rf"\[creature\] {SAPPHIRON} guid {sap}: .*?health (\d+),", log)
        changed = re.findall(rf"\[changes\] {int(unit_hex(sap), 16)}: fields .*?health (\d+)/", log)
        return int(changed[-1]) if changed else int(shown[-1]) if shown else None

    hurt = health(raid.logs()[0])
    assert hurt < top, "Sapphiron was not hurt"
    assert all(waterfall_state(log) in (None, 1) for log in raid.logs()) \
        and any(waterfall_state(log) == 1 for log in raid.logs()), "the waterfall not shut during the fight"

    killed, back, after = raid.crash(host, lambda part: f"[creature] {SAPPHIRON} guid {sap}:" in part)
    # `on`, not a toggle: the recovered sessions keep their GM toggles, and a toggle would leave them to his Cleave.
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    wait_for("the members immune again", lambda: all("Damage immunity: on for" in log for log in after()), 5)
    for member, log in enumerate(after()):
        assert sapphirons(log) == {sap}, f"member {member} sees Sapphirons {sapphirons(log)}, not {sap}"
        assert f"[creature aura] {unit_hex(sap)} received {FROST_AURA}" in log, f"member {member}: no Frost Aura"
        assert not hovering(log, sap)
        restored = health(log)
        assert abs(restored - hurt) * 100 <= top and restored < top, \
            f"member {member} sees him at {restored} health, before the crash {hurt} of {top}"
        assert waterfall_state(log) in (None, 1), f"member {member}: the waterfall opened"
    risen = wait_for("Sapphiron to rise after the crash", lambda: any(hovering(log, sap) for log in after()),
                     RISE_AFTER + 8) and time.monotonic()
    expected = back + RISE_AFTER - (checkpointed - engaged)
    assert abs(risen - expected) < 4, f"he rose {risen - back:.1f} s after the recovery, not {expected - back:.1f} s"
    wait_for("Frost Breath", lambda: all(f"[spell go] {FROST_BREATH} by {sap}" in log for log in after()),
             BREATH_AFTER_RISE + 10)
    wait_for("Sapphiron landing", lambda: all(not hovering(log, sap) for log in after()), 12)
    for member, log in enumerate(after()):
        assert log.count(f"[spell go] {FROST_BREATH} by {sap}") == 1, f"member {member}: more than one breath"
        assert sapphirons(log) == {sap}

    raid.restart(host)  # three voters again: the next crash leaves a majority
    first = host
    before = raid.checkpoints()
    raid.stage([[f"killpack:{SAPPHIRON}"], [], []])
    wait_for("Sapphiron slain", lambda: not sapphirons(after()[0]), 10)
    host = raid.next_checkpoint(before, "the checkpoint of his death", 4)
    wait_for("the waterfall open", lambda: waterfall_state(raid.logs()[0]) == 0, 5)
    _, _, since_death = raid.crash(host)
    time.sleep(3)
    for member, log in enumerate(since_death()):
        assert not sapphirons(log), f"member {member}: Sapphiron alive again"
        assert waterfall_state(log) in (None, 0), f"member {member}: the waterfall shut again"
    assert any(waterfall_state(log) == 0 for log in since_death()), "nobody sees the waterfall open after the crash"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {first} in Sapphiron's ground phase and {host} after his death; the original clients came back "
          f"to raid copy {raid.copy} with the same Sapphiron {sap} at his health ({hurt} of {top}) and Frost Aura; he "
          f"rose {risen - back:.1f} s after recovery (expected {expected - back:.1f}), breathed once and landed; slain, "
          f"his waterfall stayed open through a second crash")


def birth(fixture):
    raid = Raid(fixture)
    host = raid.next_checkpoint({tag: 0 for tag in raid.nodes}, "the birth's checkpoint", 10)
    born = time.monotonic()
    time.sleep(6)
    assert not any(sapphirons(log, living=False) for log in raid.logs()), "Sapphiron came early"
    killed, back, after = raid.crash(host)
    came = wait_for("Sapphiron after the crash", lambda: any(sapphirons(log) for log in after()),
                    COMES_AFTER_BIRTH + 8) and time.monotonic()
    expected = back + COMES_AFTER_BIRTH - (killed - born)
    assert abs(came - expected) < 4, f"he came {came - back:.1f} s after the recovery, not {expected - back:.1f} s"
    time.sleep(COMES_AFTER_BIRTH + 3)
    seen = set().union(*(sapphirons(log, living=False) for log in after()))
    assert len(seen) == 1, f"Sapphirons {seen}: the birth brought him twice"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} between Sapphiron's birth and his coming; the original clients came back to raid copy "
          f"{raid.copy} and he came once, {came - back:.1f} s after recovery (expected {expected - back:.1f})")


PHASES = {"air": air, "ground": ground, "birth": birth}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=PHASES, required=True)
    args = parser.parse_args()
    run_test(f"sapphiron-{args.phase}-recovery", PHASES[args.phase])
