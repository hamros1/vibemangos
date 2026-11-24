#!/usr/bin/env python3
"""Run the opt-in cluster failure scenarios against the local harness."""

import argparse
import time

import battlegroup_failover
from cluster_fixture import run_test
import gateway_checkpoint_retry
import quorum
import quorum_partition


CASES = (
    ("quorum-partition", quorum_partition.run),
    ("quorum", quorum.run),
    ("battlegroup-failover", battlegroup_failover.run),
    ("gateway-checkpoint-retry", gateway_checkpoint_retry.run),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeat", type=int, default=1, help="number of full runs with fresh fixtures")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be at least 1")

    start = time.monotonic()
    for iteration in range(1, args.repeat + 1):
        for name, scenario in CASES:
            print(f"== chaos run {iteration}/{args.repeat}: {name}", flush=True)
            run_test(name, scenario)
    print(f"PASS: {len(CASES)} chaos scenarios x {args.repeat} runs in {time.monotonic() - start:.1f}s", flush=True)


if __name__ == "__main__":
    main()
