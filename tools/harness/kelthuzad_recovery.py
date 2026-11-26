#!/usr/bin/env python3
"""Kill the Naxxramas worker during Kel'Thuzad's fight and resume it in the same raid copy on the same sockets.

Three scripted raid members (GMs, on a gateway) stand in Kel'Thuzad's chamber, on the trigger (4112) that begins
his fight: he channels, untouchable, while his minions come from the alcoves.

    --phase waves      the worker dies 45 seconds into the waves, with soldiers, an abomination and a soul weaver
                       alive and two soldiers slain. All three original sockets come back to the same copy with the
                       same Kel'Thuzad channelling, untouchable, the living minions and none of the slain; the next
                       abomination and soul weaver come on the saved timers, once each. The raid then leaves his
                       chamber (a wipe): he gives up. The worker dies again, and back in his chamber the raid finds
                       him at home with no minion; the trigger begins his fight again, its waves from the start.
    --phase guardians  the worker dies in his last phase, two Guardians of Icecrown come and one shackled by the
                       leader (a priest). He comes back at his health with the same two guardians, the shackled one
                       still shackled; the other three come on their timer, five in all. Slain, he opens his chamber.
"""

import argparse
import re
import time

from cluster_fixture import wait_for
from cluster_fixture import run_test
from cthun_recovery import creatures, unit_guid
from sapphiron_recovery import LAIR, MAP, Raid


KELTHUZAD, SOLDIER, ABOMINATION, WEAVER, GUARDIAN = 15990, 16427, 16428, 16429, 16441
MINIONS = (SOLDIER, ABOMINATION, WEAVER)
TRIGGER, TRIGGER_AT = 4112, (3716.38, -5106.78, 141.29)
CHAMBER_DOOR = 181228
UNTOUCHABLE = 0x0200_0000
SHACKLE, SMITE = 10955, 585
PHASE_TWO_SPELLS = (28478, 28479, 27819, 27810, 27808)
# His waves: soldiers from 5 s every 3 s, abominations from 30 s every 25 s, soul weavers from 40 s every 30 s; he
# fights at 5:25. Guardians every 10 s from 5 s after he calls for aid, five in all.
SOLDIERS_AT, ABOMINATIONS_AT, ABOMINATIONS_EVERY, WEAVERS_AT, WEAVERS_EVERY = 5, 30, 25, 40, 30
PHASE_TWO_AT, GUARDIANS_EVERY, GUARDIAN_COUNT = 325, 10, 5


def seen(logs, entry, living=False):
    return set().union(*(creatures(log, entry, living) for log in logs))


def unit_flags(log, spawn):
    shown = re.findall(rf"\[creature\] {KELTHUZAD} guid {spawn}: .*?unit flags (0x[0-9a-f]+)", log)
    return int(shown[-1], 16) if shown else None


def health(log, entry, spawn):
    shown = re.findall(rf"\[creature\] {entry} guid {spawn}: .*?health (\d+),", log)
    changed = re.findall(rf"\[changes\] {unit_guid(entry, spawn)}: fields .*?health (\d+)/", log)
    return int(changed[-1]) if changed else int(shown[-1]) if shown else None


def door_state(log, entry):
    """The door's last state the client was told (0 open, 1 shut), or None."""
    created = re.findall(rf"\[game object\] {entry} guid (\d+): .*?state (\d+)", log)
    if not created:
        return None
    guid, state = int(created[-1][0]), created[-1][1]
    rest = log.rsplit(f"[game object] {entry} guid {guid}:", 1)[1]
    for full, changed in re.findall(r"\[game object state\] (0x[0-9a-f]+) state (\d+)", rest):
        if int(full, 16) & 0xFFFFFF == guid:
            state = changed
    return int(state)


def newcomer(raid, entry, known, since=None):
    """A guid of `entry` none of `known`, once a client sees one (in its log since `since`, if given)."""
    def find():
        logs = since() if since else raid.logs()
        fresh = seen(logs, entry) - known
        return min(fresh) if fresh else None
    return find


def begin(raid):
    """The leader steps on the trigger; Kel'Thuzad's spawn guid and when his fight began (by his first soldier)."""
    kt = wait_for("Kel'Thuzad", lambda: next(iter(seen(raid.logs(), KELTHUZAD, True)), None), 10)
    raid.stage([[f"trigger:{TRIGGER}"], [], []])
    wait_for("his first soldier", lambda: seen(raid.logs(), SOLDIER) or None, SOLDIERS_AT + 5)
    return kt, time.monotonic() - SOLDIERS_AT


def waves(fixture):
    raid = Raid(fixture, at=TRIGGER_AT)
    kt, started = begin(raid)
    assert all(door_state(log, CHAMBER_DOOR) in (None, 1) for log in raid.logs()), "his chamber open in his fight"
    wait_for("an abomination", lambda: seen(raid.logs(), ABOMINATION) or None, ABOMINATIONS_AT + 6)
    wait_for("a soul weaver", lambda: seen(raid.logs(), WEAVER) or None, WEAVERS_AT - ABOMINATIONS_AT + 6)
    raid.stage([[f"killpack:one:{SOLDIER}", f"killpack:one:{SOLDIER}"], [], []])
    slain = wait_for("two soldiers slain", lambda: (lambda dead: dead if len(dead) >= 2 else None)(
        seen(raid.logs(), SOLDIER) - seen(raid.logs(), SOLDIER, True)), 10)
    host = raid.next_checkpoint(raid.checkpoints(), "a checkpoint of the waves", 5)
    checkpointed = time.monotonic()
    assert checkpointed - started < ABOMINATIONS_AT + ABOMINATIONS_EVERY - 3, "too late for the waves"
    living = {entry: seen(raid.logs(), entry, True) for entry in MINIONS}
    came = {entry: seen(raid.logs(), entry) for entry in MINIONS}
    assert len(living[ABOMINATION]) == 1 and len(living[WEAVER]) == 1 and len(living[SOLDIER]) >= 4, living

    killed, back, after = raid.crash(host, lambda part: f"[creature] {KELTHUZAD} guid {kt}:" in part
                                     and f"[creature] {ABOMINATION} guid" in part)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    outage = back - killed
    for member, log in enumerate(after()):
        assert seen([log], KELTHUZAD, True) == {kt}, f"member {member} sees Kel'Thuzads {seen([log], KELTHUZAD)}"
        assert unit_flags(log, kt) & UNTOUCHABLE, f"member {member}: Kel'Thuzad touchable after the crash"
        assert door_state(log, CHAMBER_DOOR) in (None, 1), f"member {member}: his chamber opened"
    back_alive = {entry: seen(after(), entry, True) for entry in MINIONS}
    for entry in (ABOMINATION, WEAVER):
        assert back_alive[entry] == living[entry], f"minions {entry}: {back_alive[entry]}, before {living[entry]}"
    # A soldier may have come after the checkpoint: it was not saved, and the next came on the saved timer.
    assert len(living[SOLDIER] - back_alive[SOLDIER]) <= 1, \
        f"soldiers before the crash {sorted(living[SOLDIER])}, after {sorted(back_alive[SOLDIER])}"
    assert not slain & back_alive[SOLDIER], f"slain soldiers {slain & back_alive[SOLDIER]} came back"

    # The waves go on from the saved timers, the outage not counted.
    abomination_at = wait_for("the next abomination", newcomer(raid, ABOMINATION, came[ABOMINATION], after),
                              ABOMINATIONS_AT + ABOMINATIONS_EVERY + 8) and time.monotonic()
    weaver_at = wait_for("the next soul weaver", newcomer(raid, WEAVER, came[WEAVER], after),
                         WEAVERS_AT + WEAVERS_EVERY + 8) and time.monotonic()
    for name, at, due in (("abomination", abomination_at, ABOMINATIONS_AT + ABOMINATIONS_EVERY),
                          ("soul weaver", weaver_at, WEAVERS_AT + WEAVERS_EVERY)):
        expected = started + outage + due
        assert abs(at - expected) < 4, f"the next {name} came {at - back:.1f} s after the recovery, not " \
                                       f"{expected - back:.1f} s: its timer did not go on"
    assert len(seen(after(), ABOMINATION) - came[ABOMINATION]) == 1 \
        and len(seen(after(), WEAVER) - came[WEAVER]) == 1, "a wave came twice"

    # The raid leaves his chamber (a wipe): he gives up, then the worker dies again.
    raid.restart(host)  # three voters again: the next crash leaves a majority
    first = host
    left = raid.checkpoints()
    raid.stage([[f"worldport:{MAP}:" + ":".join(map(str, LAIR))] for _ in range(3)])
    time.sleep(5)  # his next soldier finds nobody alive in his chamber
    host = raid.next_checkpoint(left, "the checkpoint of his giving up", 4)
    _, _, since_wipe = raid.crash(host)
    raid.stage([[f"worldport:{MAP}:" + ":".join(map(str, TRIGGER_AT))] for _ in range(3)])
    wait_for("the raid back in his chamber", lambda: all(f"[creature] {KELTHUZAD} guid {kt}:" in log
                                                         for log in since_wipe()), 15)
    for member, log in enumerate(since_wipe()):
        assert not unit_flags(log, kt) & UNTOUCHABLE, f"member {member}: Kel'Thuzad still channels after the wipe"
        for entry in MINIONS:
            assert not seen([log], entry, True), f"member {member}: minions {entry} after the wipe"
    assert any(door_state(log, CHAMBER_DOOR) == 0 for log in since_wipe()) \
        and all(door_state(log, CHAMBER_DOOR) in (None, 0) for log in since_wipe()), "his chamber shut after the wipe"
    before = seen(raid.logs(), SOLDIER)
    raid.stage([[f"trigger:{TRIGGER}"], [], []])
    pulled = time.monotonic()
    again = wait_for("a soldier of the next pull", newcomer(raid, SOLDIER, before), SOLDIERS_AT + 5) and time.monotonic()
    assert abs(again - pulled - SOLDIERS_AT) < 3, f"the next pull's first soldier came {again - pulled:.1f} s after " \
                                                  f"the trigger, not {SOLDIERS_AT}"
    time.sleep(1)
    assert len(seen(raid.logs(), SOLDIER) - before) == 1, "the next pull's first wave came twice"
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {first} 45 s into Kel'Thuzad's waves; the original clients came back to raid copy "
          f"{raid.copy} with the same Kel'Thuzad {kt} channelling, the {len(back_alive[SOLDIER])} soldiers, the "
          f"abomination and the soul weaver alive and the two slain gone; the next abomination came "
          f"{abomination_at - back:.1f} s and the next soul weaver {weaver_at - back:.1f} s after recovery, once each; "
          f"the raid left, he gave up, and after killing {host} the raid found him at home with no minion and began "
          f"his fight again (its first soldier {again - pulled:.1f} s after the trigger)")


def guardians(fixture):
    raid = Raid(fixture, at=TRIGGER_AT, leader_appearance=(1, 5))  # a human priest leads
    kt, started = begin(raid)
    # His minions slain as they come (and the members kept busy within their wait), till he fights.
    while not any(re.search(rf"\[spell (?:start|go)\] (?:{'|'.join(map(str, PHASE_TWO_SPELLS))}) by {kt}\b", log)
                  for log in raid.logs()):
        assert time.monotonic() - started < PHASE_TWO_AT + 40, "Kel'Thuzad never fought"
        alive = [entry for entry in MINIONS if seen(raid.logs(), entry, True)]
        # Each member says something every round: a client silent past the idle timeout is dropped.
        raid.stage([[f"killpack:{':'.join(map(str, alive))}"] if alive else ["cmd:.cheat status"],
                    ["cmd:.cheat status"], ["cmd:.cheat status"]])
        time.sleep(20)
    fought = time.monotonic()
    assert fought - started >= PHASE_TWO_AT - 2, f"he fought {fought - started:.0f} s into his fight"
    top = int(re.findall(rf"\[creature\] {KELTHUZAD} guid {kt}: .*?health (\d+),", raid.logs()[0])[-1])
    # The leader brings him to 39% and smites him (ungeared, the warriors' swings miss him): hurt below 40%, he
    # calls for aid.
    raid.stage([[f"targetnpc:{KELTHUZAD}", f"cmd:.modify hp {top * 39 // 100 + 5} {top}",
                 *[f"cmd:.debug cast {SMITE}"] * 3],
                [f"attack:{KELTHUZAD}"], [f"attack:{KELTHUZAD}"]])
    wait_for("a Guardian of Icecrown", lambda: seen(raid.logs(), GUARDIAN) or None, 20)
    first_at = time.monotonic()
    wait_for("the second guardian", lambda: len(seen(raid.logs(), GUARDIAN)) >= 2 or None, GUARDIANS_EVERY + 4)
    raid.stage([[f"targetnpc:{GUARDIAN}", f"cmd:.debug cast {SHACKLE}"], [], []])
    shackled = wait_for("a guardian shackled", lambda: next(
        (spawn for spawn in seen(raid.logs(), GUARDIAN, True)
         if f"[creature aura] {unit_guid(GUARDIAN, spawn):#018x} received {SHACKLE}" in raid.logs()[0]), None), 8)
    # His next ability or guardian checkpoints him; the clients are given half a second to see a guardian it brought.
    host = raid.next_checkpoint(raid.checkpoints(), "a checkpoint of his last phase", GUARDIANS_EVERY + 2)
    time.sleep(0.5)
    sent = seen(raid.logs(), GUARDIAN)
    assert 2 <= len(sent) < GUARDIAN_COUNT, f"guardians {sent} at the crash"
    hurt = health(raid.logs()[0], KELTHUZAD, kt)

    killed, back, after = raid.crash(host, lambda part: f"[creature] {KELTHUZAD} guid {kt}:" in part)
    raid.stage([["cmd:.cheat god on"] for _ in range(3)])
    outage = back - killed
    for member, log in enumerate(after()):
        assert seen([log], KELTHUZAD, True) == {kt}, f"member {member} sees Kel'Thuzads {seen([log], KELTHUZAD)}"
        restored = health(log, KELTHUZAD, kt)
        assert abs(restored - hurt) * 100 <= top, f"member {member} sees him at {restored}, before the crash {hurt}"
        assert seen([log], GUARDIAN, True) == sent, f"member {member} sees guardians {seen([log], GUARDIAN)}, not {sent}"
        assert door_state(log, CHAMBER_DOOR) in (None, 1), f"member {member}: his chamber opened"
    assert f"[creature aura] {unit_guid(GUARDIAN, shackled):#018x} received {SHACKLE}" in after()[0], \
        "the shackled guardian came back free"
    next_at = wait_for("the next guardian", newcomer(raid, GUARDIAN, sent, after), 2 * GUARDIANS_EVERY + 6) \
        and time.monotonic()
    expected = first_at + outage + len(sent) * GUARDIANS_EVERY
    assert abs(next_at - expected) < 4, f"the next guardian came {next_at - back:.1f} s after the recovery, not " \
                                        f"{expected - back:.1f} s"
    wait_for("five guardians", lambda: len(seen(after(), GUARDIAN) | sent) >= GUARDIAN_COUNT or None,
             (GUARDIAN_COUNT - len(sent)) * GUARDIANS_EVERY + 6)
    time.sleep(GUARDIANS_EVERY + 4)
    total = seen(after(), GUARDIAN) | sent
    assert len(total) == GUARDIAN_COUNT, f"{len(total)} Guardians of Icecrown, not {GUARDIAN_COUNT}"

    raid.stage([[f"killpack:{KELTHUZAD}"], [], []])
    wait_for("his chamber open after his death", lambda: door_state(raid.logs()[0], CHAMBER_DOOR) == 0, 10)
    raid.same_copy()
    raid.finish()
    print(f"PASS: killed {host} in Kel'Thuzad's last phase with two Guardians of Icecrown, one shackled; the original "
          f"clients came back to raid copy {raid.copy} with the same Kel'Thuzad {kt} at his health ({hurt} of {top}), "
          f"the same guardians {sorted(sent)} and guardian {shackled} still shackled; the next came "
          f"{next_at - back:.1f} s after recovery (expected {expected - back:.1f}), five in all; slain, he opened "
          f"his chamber")


PHASES = {"waves": waves, "guardians": guardians}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--phase", choices=PHASES, required=True)
    args = parser.parse_args()
    run_test(f"kelthuzad-{args.phase}-recovery", PHASES[args.phase])
