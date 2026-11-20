#!/usr/bin/env python3
"""Blizzard's instance reset intervals, into the server's data directory (beside dbc/): data/instance-resets.csv.

The 1.12.1 client's Map.dbc does not say how often a raid resets: that was the server's. Classic Era's client data
does (MapDifficulty.db2's ResetInterval, an enum: 2 Molten Core and the other 40-player raids, 3 Zul'Gurub and the
Ruins of Ahn'Qiraj, 4 Onyxia's Lair; 0 the dungeons), the intervals patch 1.9.0 set: seven days, three days, five
days (docs/FORMULAS.md, "Raid resets"). This takes the rows of 1.12's difficulties (0 the world, 1 a dungeon,
9 a 40-player raid, 148 a 20-player raid; the later seasons' are left out) for the maps the 1.12.1 Map.dbc has, from
the public export of that table (wago.tools) for one pinned build, and writes `map,reset interval,max players` for
each. The server (`ClientData.instanceResets`) maps the enum to days. Blizzard's data: not committed.

    tools/fetch-instance-resets.py DATA_DIR [BUILD]
"""
import csv, io, os, struct, sys, urllib.request

BUILD = '1.15.9.70576'
URL = 'https://wago.tools/db2/MapDifficulty/csv?build=%s'
DIFFICULTIES = {'0', '1', '9', '148'}


def map_ids(dbc_path):
    data = open(dbc_path, 'rb').read()
    _, count, fields, size, _ = struct.unpack('<4s4I', data[:20])
    return {struct.unpack_from('<I', data, 20 + i * size)[0] for i in range(count)}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    data_dir = sys.argv[1]
    build = sys.argv[2] if len(sys.argv) > 2 else BUILD
    known = map_ids(os.path.join(data_dir, 'dbc', 'Map.dbc'))
    request = urllib.request.Request(URL % build, headers={'User-Agent': 'dmangos-data-tool'})
    text = urllib.request.urlopen(request, timeout=120).read().decode('utf-8')
    rows = {}
    for row in csv.DictReader(io.StringIO(text)):
        map_id = int(row['MapID'])
        if map_id in known and row['DifficultyID'] in DIFFICULTIES:
            rows[map_id] = (map_id, int(row['ResetInterval']), int(row['MaxPlayers']))
    out = os.path.join(data_dir, 'instance-resets.csv')
    with open(out, 'w') as f:
        f.write('# map,reset interval,max players: MapDifficulty.db2 of Classic Era %s\n' % build)
        for r in sorted(rows.values()):
            f.write('%d,%d,%d\n' % r)
    print('%d maps written to %s' % (len(rows), out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
