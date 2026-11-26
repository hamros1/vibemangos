#!/usr/bin/env python3
"""Kill the Zul'Gurub worker during Arlokk's fight, or as Mandokir comes down, and resume in the same raid copy.

Three scripted raid members (GMs, on a gateway) stand in Zul'Gurub:

    --phase arlokk    by the Gong of Bethekk. The leader strikes it, High Priestess Arlokk comes ten seconds later
                      (she is a summon, so only the copy's checkpoint brings her back), the members fight her, her
                      forcefield shuts and her prowlers come. The worker dies with her at 60%. All three original
                      sockets come back to the same copy with the same Arlokk at her health, her forcefield shut and
                      her prowlers; more come. Slain, she opens her forcefield and no prowler comes after; the worker
                      that took over dies, and after recovery her forcefield is open and the gong calls no Arlokk.
    --phase mandokir  by the Vilebranch Speaker below Bloodlord Mandokir's perch. The leader slays the Speaker, which
                      sends Mandokir down, and the worker dies just after the checkpoint of that death, before he is
                      down. After recovery he is on his perch again, untouchable, comes down, and fights the members.
"""

import argparse
import re
import time

from cluster_fixture import run_test, wait_for
from cthun_recovery import creatures
from kelthuzad_recovery import door_state, health, seen
from sapphiron_recovery import Raid


MAP = 309
ARLOKK, PROWLER, GONG, FORCEFIELD = 14515, 15101, 180526, 180497
MANDOKIR, SPEAKER = 11382, 11391
BY_GONG = (-11566.2, -1627.9, 41.3)
BY_SPEAKER = (-12190.0, -1948.0, 130.3)
COMES_AFTER_GONG, PROWLERS_EVERY = 10, 8


def hurt(raid, entry, spawn, percent):
    top = int(re.findall(rf"\[creature\] {entry} guid {spawn}: .*?health (\d+),", raid.logs()[0])[-1])
    raid.stage([[f"targetnpc:{entry}", f"cmd:.modify hp {top * percent // 100} {top}"], [], []])
    wait_for(f"{entry} at {percent}%", lambda: (health(raid.logs()[0], entry, spawn) or top)
             <= top * percent // 100 + top // 100, 8)
    return top


def forcefield(logs):
    """The forcefield's state as the members last saw it (0 open, 1 shut); None if none saw it."""
    states = {door_state(log, FORCEFIELD) for log in logs} - {None}
    assert len(states) <= 1, f"the members disagree on the forcefield: {states}"
    return next(iter(states), None)


def arlokk(fixture):
    raid = Raid(fixture, at=BY_GONG, map_id=MAP)
    raid.stage([["cmd:.cheat god on", f"usego:{GONG}"], ["cmd:.cheat god on"], ["cmd:.cheat god on"]])
    arl = wait_for("Arlokk", lambda: next(iter(seen(raid.logs(), ARLOKK, True)), None), COMES_AFTER_GONG + 8)
    raid.stage([[f"attack:{ARLOKK}"] for _ in range(3)])
    wait_for("her prowlers", lambda: seen(raid.logs(), PROWLER, True) or None, PROWLERS_EVERY + 6)
    assert forcefield(raid.logs()) in (None, 1), "her forcefield open in her fight"
    top = hurt(raid, ARLOKK, arl, 60)
    host = raid.next_checkpoint(raid.checkpoints(), "a checkpoint of her fight", PROWLERS_EVERY + 4)
    hurt_to = health(raid.logs()[0], ARLOKK, arl)
    prowlers = seen(raid.logs(), PROWLER, True)

    killed, back, after = raid.crash(host, lambda part: f"[creature] {ARLOKK} guid {arl}:" in part)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    for member, log in enumerate(after()):
        assert creatures(log, ARLOKK) == {arl}, f"member {member} sees Arlokk {creatures(log, ARLOKK, False)}"
        restored = health(log, ARLOKK, arl)
        assert abs(restored - hurt_to) * 100 <= top, f"member {member} sees her at {restored}, before the crash {hurt_to}"
    assert forcefield(after()) in (None, 1), "her forcefield opened after the crash"
    # The prowlers of the last wave may have come after the checkpoint: they were not saved.
    lost = prowlers - seen(after(), PROWLER, True)
    assert len(lost) <= 2, f"prowlers {sorted(lost)} did not come back"
    known = seen(raid.logs(), PROWLER)
    wait_for("a prowler after the crash", lambda: seen(after(), PROWLER) - known or None, PROWLERS_EVERY + 6)

    raid.restart(host)  # three voters again: the next crash leaves a majority
    before = raid.checkpoints()
    raid.stage([[f"killpack:{ARLOKK}"], [], []])
    wait_for("her forcefield open after her death", lambda: forcefield(raid.logs()) == 0, 10)
    second = raid.next_checkpoint(before, "the checkpoint of her death", 5)
    sent = seen(raid.logs(), PROWLER)
    time.sleep(2 * PROWLERS_EVERY + 2)
    assert seen(raid.logs(), PROWLER) == sent, "her prowlers come on after her death"

    _, _, since = raid.crash(second)
    raid.stage([["cmd:.cheat god on", f"usego:{GONG}"], ["cmd:.cheat god on"], ["cmd:.cheat god on"]])
    wait_for("the members see her forcefield", lambda: forcefield(since()) is not None, 10)
    assert forcefield(since()) == 0, "her forcefield shut after her death and a crash"
    time.sleep(COMES_AFTER_GONG + 5)
    for member, log in enumerate(since()):
        assert not creatures(log, ARLOKK), f"member {member}: the gong called Arlokk again after her death"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} with Arlokk at 60% ({hurt_to} of {top}); the original clients came back to raid copy "
          f"{raid.copy} with the same Arlokk {arl} at her health, her forcefield shut and her prowlers, and more came; "
          f"slain, she opened her forcefield and no prowler came after; after killing {second} the forcefield stood "
          f"open and the gong called no Arlokk")


def mandokir(fixture):
    raid = Raid(fixture, at=BY_SPEAKER, map_id=MAP)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    him = wait_for("Mandokir on his perch", lambda: next(iter(seen(raid.logs(), MANDOKIR, True)), None), 10)
    wait_for("the Vilebranch Speaker", lambda: seen(raid.logs(), SPEAKER, True) or None, 10)
    before = raid.checkpoints()
    raid.stage([[f"killpack:{SPEAKER}"], [], []])
    host = raid.next_checkpoint(before, "the checkpoint of the Speaker's death", 5)
    early = any(f"[attack start] {him} ->" in log for log in raid.logs())
    killed, back, after = raid.crash(host, lambda part: f"[creature] {MANDOKIR} guid {him}:" in part)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    assert not early, "Mandokir was down and fighting before the crash"
    wait_for("Mandokir down and fighting after the crash",
             lambda: any(f"[attack start] {him} ->" in log for log in after()), 40)
    fought = time.monotonic()
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} just after the Vilebranch Speaker's death sent Mandokir down; the original clients came "
          f"back to raid copy {raid.copy}, and Mandokir {him} came down from his perch again and fought them "
          f"{fought - back:.1f} s after recovery")


PHASES = {"arlokk": arlokk, "mandokir": mandokir}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=PHASES, required=True)
    args = parser.parse_args()
    run_test(f"zulgurub-{args.phase}-recovery", PHASES[args.phase])
