#!/usr/bin/env python3
"""Blizzard's spell power coefficients, into the server's data directory (beside dbc/): data/coefficients.csv.

The 1.12.1 client's Spell.dbc has no coefficients: the share of the caster's spell power each effect gets was the
server's. Classic Era's client data (SpellEffect.db2's EffectBonusCoefficient), built from the same 1.12 game data,
has them: Frostbolt's 0.814, Shadow Word: Pain's per tick, the low-level penalty within. This takes them from the
public export of that table (wago.tools) for one pinned build, keeps the rows of spells the 1.12.1 Spell.dbc has
(base difficulty), and writes `spell,effect index,effect,aura,coefficient` for each. The server takes an effect's
coefficient from here only where the effect is the same in both (Classic Era rebuilt a few spells, e.g. Holy Light
as a script effect); otherwise it uses the 1.12 formula (docs/FORMULAS.md). Blizzard's data: not committed.

    tools/fetch-coefficients.py DATA_DIR [BUILD]
"""
import csv, io, os, struct, sys, urllib.request

BUILD = '1.15.9.70576'
URL = 'https://wago.tools/db2/SpellEffect/csv?build=%s'


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
        if spell in known and row['DifficultyID'] == '0':
            rows.append((spell, int(row['EffectIndex']), int(row['Effect']), int(row['EffectAura']),
                         float(row['EffectBonusCoefficient'] or 0)))
    rows.sort()
    out = os.path.join(data_dir, 'coefficients.csv')
    with open(out, 'w') as f:
        f.write('# spell,effect index,effect,aura,coefficient: SpellEffect.db2 of Classic Era %s\n' % build)
        for r in rows:
            f.write('%d,%d,%d,%d,%.6g\n' % r)
    print('%d effects of %d spells written to %s' % (len(rows), len({r[0] for r in rows}), out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
