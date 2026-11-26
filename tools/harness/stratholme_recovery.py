#!/usr/bin/env python3
"""Kill the Stratholme worker while its summoned encounters live and resume them in the same copy on the same sockets.

Two scripted party members (GMs, on a gateway) go into Stratholme.

    --phase ramstein  in the slaughter square, the leader slays its abominations, and Ramstein the Gorger (a summon)
                      comes out of the slaughterhouse; the leader fights him. The worker dies just after the
                      checkpoint of his coming. Both original sockets come back to the same copy with the same
                      Ramstein, hurt as he was. Slain, he calls the five Black Guards and the thirty mindless undead
                      (summons too); the worker that took over dies just after a checkpoint of the undead, with two
                      slain. After recovery the living undead and the guards are the same creatures, the slain stay
                      slain, the rest come on, thirty in all, and the last guard's death opens the Baron's door.
    --phase ysida     one member stands by the slaughterhouse, so that the Baron is there; the leader opens the
                      gauntlet's gate and the Baron's run begins: Ysida Harmon (a summon) is in her cage. The worker
                      dies just after the checkpoint of her coming. After recovery the same Ysida is caged, out of
                      reach. The leader, on "Dead Man's Plea", slays the Baron: she is saved, her cage opens and the
                      quest's objective is done. The worker that took over dies just after that checkpoint; after
                      recovery the same Ysida stands free by her open cage, and the leader hands the quest in to her.
"""

import argparse
import re
import signal
import time

from cluster_fixture import WORLD, run_test, wait_for
from dungeon_recovery import open_party, start_cluster
from horsemen_recovery import creatures, health, top_health
from kelthuzad_recovery import door_state


MAP = 329
ABOMINATIONS = (10416, 10417)
RAMSTEIN, GUARD, ZOMBIE = 10439, 10394, 11030
BARON, YSIDA = 10440, 16031
BARON_DOOR, GAUNTLET_GATE, CAGE = 175796, 175357, 181071
QUEST = 8945  # Dead Man's Plea
SQUARE = (4033.0, -3431.0, 119.6)
SLAUGHTERHOUSE = (4032.0, -3376.0, 119.8)  # the Baron loaded, out of his sight
GATE = (3729.0, -3599.0, 142.3)
NOT_ATTACKABLE = 0x2


def port(spot):
    return f"worldport:{MAP}:{spot[0]}:{spot[1]}:{spot[2]}"


def unit_flags(log, entry, spawn):
    shown = re.findall(rf"\[creature\] {entry} guid {spawn}: .*?unit flags (0x[0-9a-f]+)", log)
    return int(shown[-1], 16) if shown else None


class Party:
    """Two party members in Stratholme, driven stage by stage."""

    def __init__(self, fixture, entrance, quest=False):
        self.fixture = fixture
        characters, names, leader, client, nodes, _ = start_cluster(fixture, new_party=False)
        self.characters, self.names, self.nodes, self.leader = characters, names, nodes, leader
        if quest:
            fixture.query(f"INSERT INTO character_queststatus (guid, quest, status, rewarded) "
                          f"VALUES ({leader},{QUEST},3,0)", characters)
        first = [fixture.directory / f"stage-0-{member}" for member in range(2)]
        actions = [(f"waitactions:{first[member]}",) for member in range(2)]
        self.copy, self.logs, self.clients = open_party(fixture, characters, names, leader, client, nodes, False,
                                                        actions, map_id=MAP, entrance=port(entrance))
        self.next = first
        self.number = 0

    def stage(self, actions):
        """Each member's next actions (a list per member), written at once; each waits for its next stage after."""
        self.number += 1
        for member in range(2):
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
        line = f"instance {self.copy} of map {MAP} saved an encounter checkpoint"
        return {tag: self.fixture.log(tag).count(line) for tag in self.nodes}

    def next_checkpoint(self, before, why, seconds):
        return wait_for(why, lambda: next((tag for tag, count in self.checkpoints().items()
                                           if count > before.get(tag, 0)), None), seconds)

    def seen(self, entry, living=True, logs=None):
        return set().union(*(creatures(log, entry, living) for log in (logs or self.logs())))

    def same_copy(self):
        assert self.fixture.query(f"SELECT id FROM instance WHERE map={MAP}", self.characters) == str(self.copy), \
            "a second copy of Stratholme"
        assert self.fixture.query(f"SELECT COUNT(*) FROM character_instance WHERE instance={self.copy}",
                                  self.characters) == "2"

    def crash(self, host, expect, members=(0, 1)):
        """Kills `host` and waits for both original sockets to come back to the copy, those of `members` seeing what
        `expect` asks of their logs since; a function giving their logs since the crash."""
        offsets = list(map(len, self.logs()))
        self.nodes[host].send_signal(signal.SIGKILL)
        assert self.nodes[host].wait(timeout=10) == -signal.SIGKILL
        since = lambda: [log[offset:] for log, offset in zip(self.logs(), offsets)]
        wait_for("both original sockets back in the copy",
                 lambda: all(f"[new world] map {MAP} " in part and (member not in members or expect(part))
                             for member, part in enumerate(since())), 60)
        self.same_copy()
        # `on`, not a toggle: the recovered sessions keep their GM toggles.
        self.stage([["cmd:.cheat god on"], ["cmd:.cheat god on"]])
        return since

    def restart(self, host):
        """Starts the killed `host` again (a new incarnation, its own log), and waits for it to hold a lease."""
        again = f"{host}-again"
        self.nodes[again] = self.fixture.start(again, [WORLD, "-c", self.fixture.directory / f"{host}.json"])
        wait_for(f"{host} back in the cluster", lambda: "lease holds" in self.fixture.log(again), 45)


def ramstein(fixture):
    party = Party(fixture, SQUARE)
    party.stage([["cmd:.cheat god on"], ["cmd:.cheat god on"]])
    wait_for("the square's abominations in sight", lambda: party.seen(ABOMINATIONS[0]) and party.seen(ABOMINATIONS[1]),
             15)
    before = party.checkpoints()
    for _ in range(4):
        party.stage([[f"killpack:{':'.join(map(str, ABOMINATIONS))}"], []])
        if wait_for_quietly(lambda: party.seen(RAMSTEIN), 6):
            break
    him = wait_for("Ramstein", lambda: next(iter(party.seen(RAMSTEIN)), None), 6)
    host = party.next_checkpoint(before, "the checkpoint of Ramstein's coming", 5)
    top = top_health(party.logs()[0], RAMSTEIN, him)
    party.stage([[f"targetnpc:{RAMSTEIN}", f"cmd:.modify hp {top * 6 // 10} {top}"], []])
    wait_for("Ramstein hurt", lambda: (health(party.logs()[0], RAMSTEIN, him) or top) < top, 6)
    time.sleep(2.5)  # his hurt saved with the copy's next save
    hurt = health(party.logs()[0], RAMSTEIN, him)

    after = party.crash(host, lambda part: f"[creature] {RAMSTEIN} guid " in part)
    for member, log in enumerate(after()):
        assert creatures(log, RAMSTEIN) == {him}, f"member {member} sees Ramsteins {creatures(log, RAMSTEIN)}, " \
                                                  f"not {him}"
        restored = health(log, RAMSTEIN, him)
        assert restored < top and abs(restored - hurt) * 100 <= top, \
            f"member {member} sees Ramstein at {restored} health, before the crash {hurt} of {top}"

    party.restart(host)  # three voters again: the next crash leaves a majority
    first = host
    party.stage([[f"killpack:{RAMSTEIN}"], []])
    guards = wait_for("the five Black Guards", lambda: (lambda found: found if len(found) == 5 else None)(
        party.seen(GUARD)), 10)
    wait_for("ten mindless undead", lambda: len(party.seen(ZOMBIE)) >= 10, 15)
    party.stage([[f"killpack:one:{ZOMBIE}", f"killpack:one:{ZOMBIE}"], []])
    slain = wait_for("two undead slain", lambda: (lambda dead: dead if len(dead) >= 2 else None)(
        party.seen(ZOMBIE, living=False) - party.seen(ZOMBIE)), 8)
    before = party.checkpoints()
    host = party.next_checkpoint(before, "a checkpoint of the undead", 3)
    living = party.seen(ZOMBIE)
    came = party.seen(ZOMBIE, living=False)

    after = party.crash(host, lambda part: f"[creature] {GUARD} guid " in part)
    back_guards = party.seen(GUARD, logs=after())
    back_living = party.seen(ZOMBIE, logs=after())
    assert back_guards == guards, f"guards after the crash {sorted(back_guards)}, before {sorted(guards)}"
    # One may have come after the checkpoint: it was not saved, and the next came in its place.
    assert len(living - back_living) <= 1, f"undead before the crash {sorted(living)}, after {sorted(back_living)}"
    # Their lootable corpses come back as corpses; none of them alive.
    assert not slain & back_living, "slain undead came back to life"

    # The rest come on and are slain as they come, then the guards.
    def all_came():
        party.stage([[f"killpack:{ZOMBIE}"], []])
        time.sleep(1.5)
        total = party.seen(ZOMBIE, living=False)
        return len(total) >= 30 and not party.seen(ZOMBIE, logs=after())

    wait_for("the thirty mindless undead come and slain", all_came, 40)
    total = party.seen(ZOMBIE, living=False)
    assert len(total) <= 31, f"{len(total)} undead came: some came twice"
    assert door_state(party.logs()[0], BARON_DOOR) in (None, 1), "the Baron's door open with the guards alive"
    party.stage([[f"killpack:{GUARD}"], []])
    wait_for("the Baron's door open", lambda: door_state(party.logs()[0], BARON_DOOR) == 0, 10)
    party.same_copy()
    party.finish()
    print(f"PASS: killed {first} with Ramstein out and {host} among the mindless undead; the original clients came back "
          f"to copy {party.copy} with the same Ramstein ({him}, at {restored} of {top}), the same five guards and "
          f"living undead, {len(total)} undead in all, and the last guard's death opened the Baron's door")


def wait_for_quietly(check, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(0.25)
    return False


def ysida(fixture):
    party = Party(fixture, SLAUGHTERHOUSE, quest=True)
    party.stage([["cmd:.cheat god on"], ["cmd:.cheat god on"]])
    wait_for("the Baron in sight", lambda: party.seen(BARON), 15)
    before = party.checkpoints()
    party.stage([[port(GATE), f"usego:{GAUNTLET_GATE}", port(SLAUGHTERHOUSE)], []])
    her = wait_for("Ysida in her cage", lambda: next(iter(party.seen(YSIDA)), None), 15)
    host = party.next_checkpoint(before, "the checkpoint of the run's start", 5)
    back = f"[teleport] to {SLAUGHTERHOUSE[0]:.1f} {SLAUGHTERHOUSE[1]:.1f}"
    wait_for("the leader back from the gate",
             lambda: back in party.logs()[0].partition(f"use {GAUNTLET_GATE} ")[2], 15)

    # The leader's character was saved with that checkpoint, at the gate: it comes back there.
    after = party.crash(host, lambda part: f"[creature] {YSIDA} guid " in part, members=(1,))
    log = after()[1]
    assert creatures(log, YSIDA) == {her}, f"the member sees Ysidas {creatures(log, YSIDA)}, not {her}"
    assert unit_flags(log, YSIDA, her) & NOT_ATTACKABLE, "Ysida out of her cage"
    party.stage([[port(SLAUGHTERHOUSE)], []])
    wait_for("the leader back by the Baron", lambda: her in party.seen(YSIDA, logs=after()[:1]), 15)

    party.restart(host)
    first = host
    before = party.checkpoints()
    party.stage([[f"killpack:{BARON}"], []])
    wait_for("the quest's objective done", lambda: f"[quest objectives done] {QUEST}" in party.logs()[0], 10)
    wait_for("her cage open", lambda: door_state(party.logs()[1], CAGE) == 0, 10)
    host = party.next_checkpoint(before, "the checkpoint of the Baron's death", 5)

    after = party.crash(host, lambda part: f"[creature] {YSIDA} guid " in part)
    for member, log in enumerate(after()):
        assert creatures(log, YSIDA) == {her}, f"member {member} sees Ysidas {creatures(log, YSIDA)}, not {her}"
        assert not unit_flags(log, YSIDA, her) & NOT_ATTACKABLE, f"member {member}: Ysida still caged"
        assert door_state(log, CAGE) in (None, 0), f"member {member}: her cage shut again"
    party.stage([[f"approach:{YSIDA}:3", f"questcomplete:{YSIDA}:{QUEST}", f"questreward:{YSIDA}:{QUEST}:0"], []])
    wait_for("the quest handed in to her", lambda: f"[quest complete] {QUEST}" in party.logs()[0], 10)
    wait_for("the quest saved rewarded", lambda: fixture.query(
        f"SELECT rewarded FROM character_queststatus WHERE guid={party.leader} AND quest={QUEST}",
        party.characters) == "1", 10)
    party.same_copy()
    party.finish()
    print(f"PASS: killed {first} with the Baron's run under way and {host} after his death; the original clients came "
          f"back to copy {party.copy} with the same Ysida ({her}), caged and then free by her open cage, and the "
          f"leader handed \"Dead Man's Plea\" in to her")


PHASES = {"ramstein": ramstein, "ysida": ysida}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=PHASES, required=True)
    args = parser.parse_args()
    run_test(f"stratholme-{args.phase}-recovery", PHASES[args.phase])
