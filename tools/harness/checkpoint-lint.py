#!/usr/bin/env python3
"""Every creature an encounter script summons is either kept across a crash or listed as not kept.

A dungeon's script keeps a creature across a crash by checkpointing it (`checkpointCreature`), in a `case` of the
creature entries it hears arrive, or as it summons it. A summon its creatures' scripts make that no such case names comes back from no
checkpoint: after a crash the fight goes on without it. That may be meant (a spore, a slime that lives seconds), or a
forgotten case. Each summoned entry no checkpointing case names must be listed, with why, in
tools/harness/checkpoint-transient.txt ("file: entry: why"); this fails at one that is not, and at a listed one that
is kept now (take it off).
"""
import re, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LIST = REPO / "tools/harness/checkpoint-transient.txt"


def entries(script):
    """The entries `script` summons that no checkpointing case names."""
    summoned = set()
    # A summon kept in a variable that is checkpointed (Nefarian: `nefarianDragon = copy.summon(npcNefarian, ...)`,
    # checkpointed further on): kept.
    checkpointed = set(re.findall(r"checkpointCreature\(\s*(\w+)\s*\)", script))
    held = {entry for var, entry in re.findall(r"\b(\w+)\s*=\s*\w+\.summon\w*\(\s*(npc\w+)", script)
            if var in checkpointed}
    lines = script.split("\n")
    for i, line in enumerate(lines):
        for m in re.finditer(r"\bsummon\w*\(\s*(npc\w+|\w+\.\w+)", line):
            # Checkpointed as it comes, a few lines on (Blackrock Spire's rookery adds): kept.
            if not any("checkpointCreature(" in later for later in lines[i:i + 5]):
                summoned.add(m.group(1))
    kept = set()
    for m in re.finditer(r"case ([^:]+):(.*?)(?=\n\s*case |\n\s*default:|\n    }\n)", script, re.S):
        if "checkpointCreature(" in m.group(2):
            kept |= {x.strip().split(".")[-1] for x in m.group(1).split(",")}
    return {x for x in summoned if x.split(".")[-1] not in kept and x not in held}


def main():
    listed = {}
    for line in LIST.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            name, entry, why = (part.strip() for part in line.split(":", 2))
            listed[(name, entry)] = why
    found = set()
    for path in sorted((REPO / "source/dmangos/scripts").glob("*.d")):
        script = path.read_text()
        if "checkpointCreature(" in script:
            found |= {(path.name, entry) for entry in entries(script)}
    new = sorted(found - listed.keys())
    gone = sorted(listed.keys() - found)
    for name, entry in new:
        print(f"{name}: {entry}: summoned, never checkpointed, not listed in {LIST.name}")
    for name, entry in gone:
        print(f"{name}: {entry}: listed in {LIST.name} but checkpointed (or no longer summoned): take it off")
    print(f"{len(found)} summoned entries not kept across a crash, each listed" if not new and not gone else "")
    return 1 if new or gone else 0


sys.exit(main())
