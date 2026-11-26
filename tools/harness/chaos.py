#!/usr/bin/env python3
"""Run the opt-in cluster failure scenarios against the local harness.

  chaos.py [--repeat N] [-j JOBS] [CASE ...]

With -j, the cases run in separate processes, JOBS at a time, each one's output in its fixture's log
(`<harness>/chaos-<case>.log`); the cases that change one of the database server's global settings
(LOCKWAIT) run one after another among themselves. Each case already has its own directory, schemas and
ports. With no -j, the default is as many as the free memory allows (about 6 GB a case), at most 4.
Naming cases runs only those.
"""

import argparse
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import ahnqiraj_recovery
import battlegroup_failover
from cluster_fixture import HARNESS, run_test
import cthun_recovery
import departure_retry
import gateway_checkpoint_retry
import gateway_return
import horsemen_recovery
import kelthuzad_recovery
import lease_lapse_arrival
import loot_award_crash
import migration_stall
import quorum
import quorum_partition
import ragnaros_recovery
import sapphiron_recovery
import stall_release
import standby_bundle
import standby_login
import stratholme_recovery
import worker_rejoin
import zulgurub_recovery


CASES = (
    ("quorum-partition", quorum_partition.run),
    ("quorum", quorum.run),
    ("battlegroup-failover", battlegroup_failover.run),
    ("gateway-checkpoint-retry", gateway_checkpoint_retry.run),
    ("departure-retry", departure_retry.run),
    ("lease-lapse-arrival", lease_lapse_arrival.run),
    ("worker-rejoin", worker_rejoin.run),
    ("stall-release", stall_release.run),
    ("gateway-return", gateway_return.run),
    ("cthun-transition-recovery", cthun_recovery.transition),
    ("cthun-stomach-recovery", cthun_recovery.stomach),
    ("sapphiron-air-recovery", sapphiron_recovery.air),
    ("sapphiron-ground-recovery", sapphiron_recovery.ground),
    ("sapphiron-birth-recovery", sapphiron_recovery.birth),
    ("horsemen-kills-recovery", horsemen_recovery.kills),
    ("horsemen-wipe-recovery", horsemen_recovery.wipe),
    ("kelthuzad-waves-recovery", kelthuzad_recovery.waves),
    ("kelthuzad-guardians-recovery", kelthuzad_recovery.guardians),
    ("kelthuzad-chains-recovery", kelthuzad_recovery.chains),
    ("stratholme-ramstein-recovery", stratholme_recovery.ramstein),
    ("stratholme-ysida-recovery", stratholme_recovery.ysida),
    ("ragnaros-fight-recovery", ragnaros_recovery.fight),
    ("ragnaros-wipe-recovery", ragnaros_recovery.wipe),
    ("majordomo-recovery", ragnaros_recovery.majordomo),
    ("zulgurub-arlokk-recovery", zulgurub_recovery.arlokk),
    ("zulgurub-mandokir-recovery", zulgurub_recovery.mandokir),
    ("aq20-army-recovery", ahnqiraj_recovery.army),
    ("aq40-trio-recovery", ahnqiraj_recovery.trio),
    ("aq40-twins-recovery", ahnqiraj_recovery.twins),
    ("aq40-ouro-recovery", ahnqiraj_recovery.ouro),
    ("aq40-viscidus-recovery", ahnqiraj_recovery.viscidus),
    ("loot-award-crash", loot_award_crash.main),
    ("migration-stall", migration_stall.run),
    ("standby-login", standby_login.run),
    ("standby-bundle", standby_bundle.run),
)

# They set the database server's GLOBAL innodb_lock_wait_timeout for their run and restore it after.
LOCKWAIT = {"departure-retry", "stall-release", "loot-award-crash", "migration-stall"}


def default_jobs():
    try:
        with open("/proc/meminfo") as meminfo:
            available = next(int(line.split()[1]) for line in meminfo if line.startswith("MemAvailable:"))
    except (OSError, StopIteration):
        return 1
    return max(1, min(4, available // (6 * 1024 * 1024)))


def run_parallel(cases, jobs, repeat):
    """Each case in its own process; True if every one passed."""
    results, lock = [], threading.Lock()
    slots = threading.Semaphore(jobs)
    lockwait = threading.Lock()

    def one(name, iteration):
        log = HARNESS / f"chaos-{name}-{iteration}.log"
        with (lockwait if name in LOCKWAIT else _nothing()), slots:  # a waiting one holds no slot
            start = time.monotonic()
            with open(log, "w") as out:
                code = subprocess.call([sys.executable, "-u", __file__, "--case", name], stdout=out,
                                       stderr=subprocess.STDOUT, cwd=Path(__file__).parent)
            tail = log.read_text().strip().splitlines()[-1:] or [""]
            with lock:
                results.append((name, code == 0))
                print(f"== {name} (run {iteration}): {'PASS' if code == 0 else 'FAIL'} in "
                      f"{time.monotonic() - start:.0f}s: {tail[0]}" + ("" if code == 0 else f" (log: {log})"),
                      flush=True)

    runs = [(name, iteration) for iteration in range(1, repeat + 1) for name, _ in cases]
    runs.sort(key=lambda run: run[0] not in LOCKWAIT)  # the serialized chain starts first: it is the longest
    threads = [threading.Thread(target=one, args=run) for run in runs]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return all(ok for _, ok in results)


class _nothing:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repeat", type=int, default=1, help="number of full runs with fresh fixtures")
    parser.add_argument("-j", "--jobs", type=int, default=None, help="cases at once (default: by free memory)")
    parser.add_argument("--case", help=argparse.SUPPRESS)  # run one case in this process (used by -j)
    parser.add_argument("names", nargs="*", help="only these cases")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be at least 1")
    known = dict(CASES)
    if args.case:
        run_test(args.case, known[args.case])
        return
    unknown = [n for n in args.names if n not in known]
    if unknown:
        parser.error(f"unknown case(s) {', '.join(unknown)}; known: {', '.join(known)}")
    cases = [(n, s) for n, s in CASES if not args.names or n in args.names]
    jobs = args.jobs if args.jobs is not None else default_jobs()

    start = time.monotonic()
    if jobs > 1:
        print(f"running {len(cases)} case(s) x {args.repeat}, {jobs} at once", flush=True)
        if not run_parallel(cases, jobs, args.repeat):
            raise SystemExit(f"FAIL: a chaos scenario failed ({time.monotonic() - start:.1f}s)")
    else:
        for iteration in range(1, args.repeat + 1):
            for name, scenario in cases:
                print(f"== chaos run {iteration}/{args.repeat}: {name}", flush=True)
                run_test(name, scenario)
    print(f"PASS: {len(cases)} chaos scenarios x {args.repeat} runs in {time.monotonic() - start:.1f}s", flush=True)


if __name__ == "__main__":
    main()
