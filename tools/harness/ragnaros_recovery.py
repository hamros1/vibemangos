#!/usr/bin/env python3
"""Kill the Molten Core worker during Ragnaros' fight and resume it in the same raid copy on the same sockets.

Three scripted raid members (GMs, on a gateway) stand by Ragnaros' lair in a copy whose saved state has every rune
doused and Majordomo's fight won: the copy's own state, written with those encounters ended, then brought in by
killing its worker. Majordomo waits by the lair; the leader asks him, he summons Ragnaros and is burnt, and Ragnaros
fights the raid. Ragnaros is a summon, so only the copy's checkpoint brings him back.

    --phase fight  the worker dies with Ragnaros at 70%. All three original sockets come back to the same copy with
                   the same Ragnaros at his health, fighting, and no Majordomo; he submerges with his eight Sons of
                   Flame three minutes into his fight, the outage not counted. Slain, the sons let him come up, and
                   slain, he stays dead: the worker that took over dies, and after recovery neither he nor Majordomo is
                   there.
    --phase wipe   the raid dies with Ragnaros fighting, and the worker dies just after the checkpoint of the wipe.
                   After recovery Majordomo waits by the lair again, and, asked, summons Ragnaros anew (another
                   creature), who fights the raid.
"""

import argparse
import re
import time

from cluster_fixture import run_test, wait_for
from cthun_recovery import creatures, unit_guid
from kelthuzad_recovery import health, seen
from sapphiron_recovery import Raid


MAP = 409
MAJORDOMO, RAGNAROS, SON = 12018, 11502, 12143
LAIR = (845.0, -815.0, -229.6)
ATTUNEMENT = 7848  # Attunement to the Core
SPELLS = (20565, 21154, 20566, 21908)  # Magma Blast, Might of Ragnaros, Wrath of Ragnaros, Lava Burst
EMERGE = 20568
SUBMERGE_AFTER, SONS = 180, 8
MIGHT_AFTER = 11  # his first Might of Ragnaros, at the leader (a mage): his first checkpoint after the pull
DATA_PREFIX = "dmangos-script:"
# The copy's encounters as saved, one byte each: Lucifron slain (3), every rune doused (4), Majordomo's fight won (3),
# Ragnaros not fought (0).
WON = bytes([3] + [4] * 7 + [3, 0])
FAILED = 2


def host_of(raid, line):
    """The live node whose log has `line` last."""
    return next(tag for tag in reversed(list(raid.nodes)) if raid.nodes[tag].poll() is None
                and line in raid.fixture.log(tag))


def fights(log, spawn):
    """Whether `log` shows Ragnaros `spawn` fighting: swinging at a member, or casting one of his spells."""
    return re.search(rf"\[swing\] {spawn} ->|\[spell (?:start|go)\] (?:{'|'.join(map(str, SPELLS))}) by {spawn}\b",
                     log) is not None


def saved_ragnaros(raid):
    """Ragnaros' encounter as the copy's saved state in the database has it (None before it is saved)."""
    data = raid.fixture.query(f"SELECT IFNULL(data, '') FROM instance WHERE id={raid.copy}", raid.characters)
    layout = data[len(DATA_PREFIX):].split(":", 1)[0] if data.startswith(DATA_PREFIX) else ""
    return int(layout[16 + 2 * 9:16 + 2 * 10], 16) if len(layout) == 2 * (8 + len(WON)) else None


def seed(raid):
    """The copy's saved state, with the runes doused and Majordomo's fight won, brought in by killing its worker."""
    fixture, copy = raid.fixture, raid.copy
    host = host_of(raid, f"instance {copy} of map {MAP} made")
    data = wait_for("the copy's saved state", lambda: (lambda d: d if d.startswith(DATA_PREFIX) else None)(
        fixture.query(f"SELECT IFNULL(data, '') FROM instance WHERE id={copy}", raid.characters)), 10)
    layout = data[len(DATA_PREFIX):].split(":", 1)[0]
    assert len(layout) == 2 * (8 + len(WON)), f"the copy's saved state {data!r}"
    fixture.query(f"UPDATE instance SET data='{DATA_PREFIX}{layout[:16]}{WON.hex()}' WHERE id={copy}",
                  raid.characters)
    # Nothing of the copy saved the members in it yet: their saves put them by the lair, as a save there would.
    fixture.query(f"UPDATE characters SET map={MAP}, position_x={LAIR[0]}, position_y={LAIR[1]}, "
                  f"position_z={LAIR[2]}", raid.characters)
    _, _, after = raid.crash(host, lambda part: f"[creature] {MAJORDOMO} guid" in part)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    raid.restart(host)  # three voters again: the next crash leaves a majority
    majordomo = wait_for("Majordomo by the lair", lambda: next(iter(seen(after(), MAJORDOMO, True)), None), 10)
    return majordomo, after


def summon(raid, majordomo):
    """The leader asks Majordomo; Ragnaros' spawn guid, and when his fight began (he attacks the nearest member)."""
    raid.stage([[f"npc:{MAJORDOMO}", "gossip", "select:0", "select:0", "select:0"], [], []])
    rag = wait_for("Ragnaros summoned", lambda: next(iter(seen(raid.logs(), RAGNAROS, True)), None), 40)
    wait_for("Majordomo burnt", lambda: not seen(raid.logs(), MAJORDOMO, True) or None, 60)
    # Each member says something every round: a client waiting on its stage past its limit fails.
    raid.stage([["cmd:.cheat status"] for _ in range(3)])
    wait_for("Ragnaros fighting", lambda: any(f"[attack start] {rag} ->" in log for log in raid.logs()), 30)
    return rag, time.monotonic()


def hurt(raid, rag, percent):
    top = int(re.findall(rf"\[creature\] {RAGNAROS} guid {rag}: .*?health (\d+),", raid.logs()[0])[-1])
    raid.stage([[f"targetnpc:{RAGNAROS}", f"cmd:.modify hp {top * percent // 100} {top}"], [], []])
    wait_for(f"Ragnaros at {percent}%", lambda: (health(raid.logs()[0], RAGNAROS, rag) or top) <= top * percent // 100
             + top // 100, 8)
    return top


def fight(fixture):
    raid = Raid(fixture, at=LAIR, leader_appearance=(1, 8), map_id=MAP, attunement=ATTUNEMENT)  # a human mage leads
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    majordomo, _ = seed(raid)
    rag, pulled = summon(raid, majordomo)
    top = hurt(raid, rag, 70)
    before = raid.checkpoints()
    host = raid.next_checkpoint(before, "a checkpoint of his fight", MIGHT_AFTER + 4)
    hurt_to = health(raid.logs()[0], RAGNAROS, rag)

    killed, back, after = raid.crash(host, lambda part: f"[creature] {RAGNAROS} guid {rag}:" in part)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    outage = back - killed
    for member, log in enumerate(after()):
        assert creatures(log, RAGNAROS) == {rag}, f"member {member} sees Ragnaros {creatures(log, RAGNAROS, False)}"
        restored = health(log, RAGNAROS, rag)
        assert abs(restored - hurt_to) * 100 <= top, f"member {member} sees him at {restored}, before the crash {hurt_to}"
        assert not creatures(log, MAJORDOMO), f"member {member}: Majordomo came again during Ragnaros' fight"
    wait_for("Ragnaros fighting after the crash", lambda: any(fights(log, rag) for log in after()), 15)

    # Three minutes into his fight, the outage not counted: under the lava, his sons come.
    raid.restart(host)
    deadline = pulled + outage + SUBMERGE_AFTER
    while time.monotonic() < deadline - 20:
        time.sleep(min(60, deadline - 20 - time.monotonic()))
        raid.stage([["cmd:.cheat status"] for _ in range(3)])
    assert not seen(after(), SON), "his sons came early"
    sons = wait_for("his Sons of Flame", lambda: (lambda found: found if len(found) >= SONS else None)(
        seen(after(), SON, True)), 30)
    came = time.monotonic()
    assert abs(came - deadline) < 5, f"he submerged {came - pulled - outage:.1f} s into his fight, not {SUBMERGE_AFTER}"
    raid.stage([[f"killpack:{SON}"], [], []])
    wait_for("Ragnaros up from the lava", lambda: any(f"[spell go] {EMERGE} by {rag}" in log for log in after()), 15)

    before = raid.checkpoints()
    raid.stage([[f"killpack:{RAGNAROS}"], [], []])
    wait_for("Ragnaros slain", lambda: not creatures(raid.logs()[0], RAGNAROS) or None, 10)
    second = raid.next_checkpoint(before, "the checkpoint of his death", 5)
    _, _, since = raid.crash(second)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    time.sleep(5)
    for member, log in enumerate(since()):
        assert not creatures(log, RAGNAROS) and not creatures(log, MAJORDOMO), \
            f"member {member}: Ragnaros or Majordomo back after his death"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} with Ragnaros at 70% ({hurt_to} of {top}); the original clients came back to raid copy "
          f"{raid.copy} with the same Ragnaros {rag} at his health and no Majordomo; he submerged "
          f"{came - pulled - outage:.1f} s into his fight with {len(sons)} Sons of Flame, came up once they were "
          f"slain, and slain stayed dead: after killing {second}, neither he nor Majordomo came back")


def wipe(fixture):
    raid = Raid(fixture, at=LAIR, leader_appearance=(1, 8), map_id=MAP, attunement=ATTUNEMENT)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    majordomo, _ = seed(raid)
    rag, _ = summon(raid, majordomo)
    host = host_of(raid, f"instance {raid.copy} of map {MAP} saved an encounter checkpoint")
    raid.stage([["cmd:.cheat god off", "wait:1", *(f"cmd:.killplr {name}" for name in raid.names)],
                ["cmd:.cheat god off"], ["cmd:.cheat god off"]])
    wait_for("the wipe saved (his encounter failed)", lambda: saved_ragnaros(raid) == FAILED or None, 20)
    killed, back, after = raid.crash(host, lambda part: f"[creature] {MAJORDOMO} guid" in part)
    raid.stage([["cmd:.revive", "cmd:.cheat god on"] for _ in range(3)])
    for member, log in enumerate(after()):
        assert not creatures(log, RAGNAROS), f"member {member} sees Ragnaros back from his failed fight"
    again = wait_for("Majordomo by the lair again", lambda: next(iter(seen(after(), MAJORDOMO, True)), None), 10)
    assert again != majordomo, "the same Majordomo"
    raid.stage([[f"npc:{MAJORDOMO}", "gossip", "select:0", "select:0", "select:0"], [], []])
    anew = wait_for("Ragnaros summoned again", lambda: next(iter(seen(after(), RAGNAROS, True)), None), 40)
    assert anew != rag, "the same Ragnaros"
    raid.stage([["cmd:.cheat status"] for _ in range(3)])
    wait_for("Ragnaros fighting again", lambda: any(fights(log, anew) for log in after()), 60)
    raid.same_copy()
    raid.finish()
    print(f"PASS: the raid wiped in Ragnaros' fight and {host} was killed; the original clients came back to raid "
          f"copy {raid.copy} with Majordomo by the lair again and no Ragnaros; asked, he summoned Ragnaros {anew} "
          f"anew, who fought the raid")


PHASES = {"fight": fight, "wipe": wipe}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=PHASES, required=True)
    args = parser.parse_args()
    run_test(f"ragnaros-{args.phase}-recovery", PHASES[args.phase])
