#!/usr/bin/env python3
"""Summarize observable events around Gluth's Decimate from a Classic Era combat log."""

import argparse
import csv
import gzip
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

# Both early Classic timestamps without a year and modern Era timestamps with a UTC offset.
LINE = re.compile(r"^(\d+/\d+(?:/\d{4})?)\s+(\d+:\d+:\d+\.\d+)(?:[+-]\d+(?::\d+)?)?\s+(.+)$")
GLUTH, CHOW = 15932, 16360


def npc_id(guid):
    parts = guid.split("-")
    if len(parts) == 7 and parts[0] in ("Creature", "Vehicle") and parts[5].isdigit():
        return int(parts[5])
    return None


@dataclass
class Pull:
    start: datetime
    encounter: str
    decimates: int = 0
    last: datetime | None = None
    swings: int = 0
    frenzies: int = 0
    wounds: int = 0
    observed: set = field(default_factory=set)
    summoned: set = field(default_factory=set)
    deaths: set = field(default_factory=set)
    devoured: set = field(default_factory=set)

    def row(self, now, event, marker=""):
        return (event, round((now - self.start).total_seconds(), 3), self.decimates, self.swings,
                self.frenzies, self.wounds, len(self.observed), len(self.summoned),
                len(self.deaths), len(self.devoured), marker)

    def observe(self, now, fields):
        if len(fields) < 9:
            return
        event, source, target = fields[0], fields[1], fields[5]
        if npc_id(source) == CHOW:
            self.observed.add(source)
        if npc_id(target) == CHOW:
            self.observed.add(target)
            if event == "SPELL_SUMMON":
                self.summoned.add(target)
            if event in ("UNIT_DIED", "UNIT_DESTROYED"):
                self.deaths.add(target)
        if npc_id(source) != GLUTH:
            return
        if event in ("SWING_DAMAGE", "SWING_MISSED"):
            self.swings += 1
        if len(fields) < 10:
            return
        spell = fields[9]
        if event == "SPELL_CAST_SUCCESS":
            self.frenzies += spell == "28371"
            self.wounds += spell == "25646"
            if spell == "28239" and npc_id(target) == CHOW:
                self.devoured.add(target)
        cast_marker = spell == "28374" and (
            event == "SPELL_CAST_SUCCESS" or (event == "SPELL_AURA_APPLIED" and target == source)
        )
        damage_marker = spell == "28375" and event in ("SPELL_DAMAGE", "SPELL_MISSED")
        if (cast_marker or damage_marker) and (self.last is None or now - self.last > timedelta(seconds=1)):
            # The cast, its self-stun and each target's damage can all appear for one use.
            self.last = now
            self.decimates += 1
            return self.row(now, "decimate", f"{event}:{spell}")


def parse(lines, encounter_name="Gluth"):
    pull = None
    number = 0
    for line in lines:
        match = LINE.match(line)
        if not match:
            continue
        date, time, body = match.groups()
        fields = next(csv.reader([body]))
        if not fields:
            continue
        event = fields[0]
        if event == "ENCOUNTER_START":
            pull = None
            if len(fields) < 3 or fields[2].casefold() != encounter_name.casefold():
                continue
        elif pull is None:
            continue
        undated = date.count("/") == 1
        if undated:
            date += "/2000"  # a leap year for early clients without a year
        now = datetime.strptime(date + " " + time, "%m/%d/%Y %H:%M:%S.%f")
        if undated and pull and pull.start.month == 12 and now.month == 1:
            now = now.replace(year=2001)
        if event == "ENCOUNTER_START":
            number += 1
            pull = Pull(now, fields[1])
        elif event == "ENCOUNTER_END" and len(fields) >= 2 and fields[1] == pull.encounter:
            yield (number, *pull.row(now, "end"))
            pull = None
        elif row := pull.observe(now, fields):
            yield (number, *row)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path, help="WoWCombatLog*.txt or .txt.gz")
    parser.add_argument("--encounter-name", default="Gluth", help="localized name in ENCOUNTER_START")
    args = parser.parse_args()
    writer = csv.writer(sys.stdout)
    writer.writerow(("file", "pull", "event", "elapsed_s", "decimates", "boss_swings", "frenzy_casts",
                     "mortal_wound_casts", "chows_seen", "chow_summons_seen", "chow_deaths_seen", "devours_seen",
                     "marker"))
    for path in args.files:
        opener = gzip.open if path.suffix == ".gz" else open
        with opener(path, "rt", encoding="utf-8-sig", errors="replace") as stream:
            for row in parse(stream, args.encounter_name):
                writer.writerow((path.name, *row))


if __name__ == "__main__":
    main()
