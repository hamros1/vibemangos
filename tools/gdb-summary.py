"""Counts functions in the stacks tools/gdb-sample.py recorded: how often each appears in a sample
(inclusive) and how often it is the innermost frame (leaf), leaving out samples idle in select.

    python3 tools/gdb-summary.py samples.txt [pattern]
"""
import collections
import re
import sys


def frame_name(line):
    match = re.match(r"#\d+\s+(?:0x[0-9a-f]+ in )?(.+?) \(", line)
    if not match:
        return None
    return re.sub(r"!\(.*?\)", "!(..)", match.group(1))[:110]


def main():
    samples = open(sys.argv[1]).read().split("\n----\n")
    pattern = re.compile(sys.argv[2] if len(sys.argv) > 2 else "dmangos|deflate|compress|gc")
    inclusive, leaf = collections.Counter(), collections.Counter()
    busy = idle = 0
    for sample in samples:
        frames = [f for f in (frame_name(l) for l in sample.splitlines() if l.startswith("#")) if f]
        if not frames:
            continue
        if any("select" in f for f in frames[:3]):
            idle += 1
            continue
        busy += 1
        leaf[frames[0]] += 1
        for f in set(frames):
            inclusive[f] += 1
    print(f"{busy} busy samples, {idle} idle")
    print("--- inclusive")
    for name, n in inclusive.most_common(200):
        if pattern.search(name):
            print(f"{n:5d} {100.0 * n / busy:5.1f}%  {name}")
    print("--- leaf")
    for name, n in leaf.most_common(20):
        print(f"{n:5d} {100.0 * n / busy:5.1f}%  {name}")


if __name__ == "__main__":
    main()
