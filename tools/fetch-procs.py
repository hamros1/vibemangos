#!/usr/bin/env python3
"""Blizzard's proc data, into the server's data directory (beside dbc/): data/procs.csv.

The 1.12.1 client's Spell.dbc has each aura's ProcFlags, ProcChance and ProcCharges, but not how long a proc waits
before it may come again: that was the server's. Classic Era's client data (SpellAuraOptions.db2, built from the
same 1.12 game data) has it as ProcCategoryRecovery (milliseconds), beside its own ProcTypeMask, ProcChance and
ProcCharges. This takes the table from the public export (wago.tools) for one pinned build, keeps the rows of
spells the 1.12.1 Spell.dbc has (base difficulty) that proc or wait at all, and writes
`spell,proc type mask 0,proc type mask 1,proc chance,proc category recovery,proc charges` for each.

The server (`ClientData.procs`) takes a row's recovery only where the row is the spell as 1.12 has it: its mask
(bits 0 to 20, which mean what 1.12's ProcFlags bits mean), chance and charges the same as Spell.dbc's. Classic Era
changed some auras afterwards (Omen of Clarity procs from spells there); those keep the world database's
`spell_proc_event` cooldown. Blizzard's data: not committed. docs/FORMULAS.md, "Procs".

    tools/fetch-procs.py DATA_DIR [BUILD]
"""
import csv, io, os, struct, sys, urllib.request

BUILD = '1.15.9.70576'
URL = 'https://wago.tools/db2/SpellAuraOptions/csv?build=%s'


def spell_ids(dbc_path):
    data = open(dbc_path, 'rb').read()
    _, count, fields, size, _ = struct.unpack('<4s4I', data[:20])
    return {struct.unpack_from('<I', data, 20 + i * size)[0] for i in range(count)}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    data_dir = sys.argv[1]
    build = sys.argv[2] if len(sys.argv) > 2 else BUILD
    known = spell_ids(os.path.join(data_dir, 'dbc', 'Spell.dbc'))
    request = urllib.request.Request(URL % build, headers={'User-Agent': 'dmangos-data-tool'})
    text = urllib.request.urlopen(request, timeout=120).read().decode('utf-8')
    rows = []
    for row in csv.DictReader(io.StringIO(text)):
        spell = int(row['SpellID'])
        procs = row['ProcTypeMask_0'] != '0' or row['ProcTypeMask_1'] != '0' or row['ProcCategoryRecovery'] != '0'
        if spell in known and row['DifficultyID'] == '0' and procs:
            rows.append((spell, int(row['ProcTypeMask_0']) & 0xffffffff, int(row['ProcTypeMask_1']) & 0xffffffff,
                         int(row['ProcChance']), int(row['ProcCategoryRecovery']), int(row['ProcCharges'])))
    rows.sort()
    out = os.path.join(data_dir, 'procs.csv')
    with open(out, 'w') as f:
        f.write('# spell,proc type mask 0,proc type mask 1,proc chance,proc category recovery,proc charges: '
                'SpellAuraOptions.db2 of Classic Era %s\n' % build)
        for r in rows:
            f.write('%d,%d,%d,%d,%d,%d\n' % r)
    print('%d spells written to %s' % (len(rows), out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
