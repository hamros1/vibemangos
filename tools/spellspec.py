#!/usr/bin/env python3
"""What every spell a player can learn is supposed to do, from the 1.12.1 client itself: its tooltip (Spell.dbc's
description, with the numbers the spell's data gives filled in), and how it does it: what in it the data alone
does not say, so the server's own code must (a dummy or script effect, a dummy aura, a proc, a class script, an
aura state, a modifier of other spells). Each such spell is listed with where the server does it and whether a test
casts it on the real data (source/dmangos/world/realspelltests.d, realclassspelltests.d, realclass_*.d). Writes docs/spells/.

    tools/spellspec.py MYSQL_COMMAND... -- DBC_DIR

MYSQL_COMMAND is a mariadb client invocation for the world database that takes `-B -N -e QUERY`
(e.g. ~/dmangos-server/mysql.sh classicmangos).
"""
import collections, glob, os, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, '..')
SOURCE = os.path.join(REPO, 'source', 'dmangos')
OUT = os.path.join(REPO, 'docs', 'spells')

LEARN_SPELL, TRIGGER_SPELL = 36, 64
PROC_TRIGGER_SPELL, PROC_TRIGGER_DAMAGE, PERIODIC_TRIGGER_SPELL = 42, 43, 23
DUMMY, SCRIPT_EFFECT, SEND_EVENT, APPLY_AURA = 3, 77, 61, 6
AURA_DUMMY, OVERRIDE_CLASS_SCRIPTS, ADD_TARGET_TRIGGER = 4, 112, 109
ADD_FLAT_MODIFIER, ADD_PCT_MODIFIER = 107, 108
# Spell.dbc, 1.12.1: the English name, rank, description and aura tooltip.
DBC_NAME, DBC_RANK, DBC_DESCRIPTION, DBC_TOOLTIP = 120, 129, 138, 147

CLASSES = {1: 'warrior', 2: 'paladin', 3: 'hunter', 4: 'rogue', 5: 'priest', 7: 'shaman', 8: 'mage', 9: 'warlock',
           11: 'druid'}
FAMILY_CLASS = {3: 'mage', 4: 'warrior', 5: 'warlock', 6: 'priest', 7: 'druid', 8: 'rogue', 9: 'hunter',
                10: 'paladin', 11: 'shaman'}
COLUMNS = ('Id SpellName Rank1 School Category RecoveryTime CategoryRecoveryTime StartRecoveryCategory '
           'StartRecoveryTime DurationIndex RangeIndex ProcFlags ProcChance ProcCharges StackAmount CasterAuraState '
           'TargetAuraState SpellFamilyName SpellFamilyFlags Attributes ManaCost ManaCostPercentage PowerType '
           'MaxAffectedTargets').split()
PER_EFFECT = ('Effect EffectApplyAuraName EffectBasePoints EffectBaseDice EffectDieSides EffectAmplitude '
              'EffectTriggerSpell EffectMiscValue EffectRadiusIndex EffectChainTarget EffectMultipleValue '
              'EffectPointsPerComboPoint EffectItemType EffectImplicitTargetA1').split()


def query(mysql, sql):
    out = subprocess.run(mysql + ['-B', '-N', '-e', sql], check=True, capture_output=True, text=True).stdout
    return [line.split('\t') for line in out.splitlines() if line]


def dbc(path):
    data = open(path, 'rb').read()
    _, count, fields, size, _ = struct.unpack('<4s4I', data[:20])
    strings = data[20 + count * size:]
    rows = [struct.unpack('<%dI' % fields, data[20 + i * size:20 + i * size + 4 * fields]) for i in range(count)]

    def text(offset):
        end = strings.index(b'\0', offset)
        return strings[offset:end].decode('utf-8', 'replace')
    return rows, text


def number(v):
    try:
        return int(v)
    except ValueError:
        return float(v)


def as_float(u):
    return struct.unpack('<f', struct.pack('<I', u))[0]


def enum_names(name):
    text = open(os.path.join(SOURCE, 'world', 'spellids.d')).read()
    start = text.index('enum ' + name)
    names = {}
    for line in text[start:text.index('}', start)].split('\n'):
        m = re.match(r'\s*(\w+)\s*=\s*(\d+)', line)
        if m:
            names[int(m.group(2))] = m.group(1)
    return names


class Data:
    def __init__(self, mysql, dbc_dir):
        cols = COLUMNS + [c + str(i) if not c.endswith('A1') else 'EffectImplicitTargetA' + str(i)
                          for c in PER_EFFECT for i in (1, 2, 3)]
        self.spells = {}
        for row in query(mysql, 'SELECT %s FROM spell_template' % ', '.join(cols)):
            d = dict(zip(cols, row))
            s = {k: (d[k] if k in ('SpellName', 'Rank1') else number(d[k]))
                 for k in COLUMNS}
            s['effects'] = []
            for i in (1, 2, 3):
                e = {}
                for c in PER_EFFECT:
                    key = c + str(i) if not c.endswith('A1') else 'EffectImplicitTargetA' + str(i)
                    v = d[key]
                    e[c.rstrip('A1') if c.endswith('A1') else c] = number(v)
                s['effects'].append(e)
            self.spells[s['Id']] = s
        rows, text = dbc(os.path.join(dbc_dir, 'Spell.dbc'))
        self.text = {}
        for r in rows:
            self.text[r[0]] = (text(r[DBC_NAME]), text(r[DBC_RANK]), text(r[DBC_DESCRIPTION]), text(r[DBC_TOOLTIP]))
        self.durations = {r[0]: (r[1], r[3]) for r in dbc(os.path.join(dbc_dir, 'SpellDuration.dbc'))[0]}
        self.radii = {r[0]: as_float(r[1]) for r in dbc(os.path.join(dbc_dir, 'SpellRadius.dbc'))[0]}
        self.ranges = {r[0]: as_float(r[2]) for r in dbc(os.path.join(dbc_dir, 'SpellRange.dbc'))[0]}
        self.spell_class = {}
        for r in dbc(os.path.join(dbc_dir, 'SkillLineAbility.dbc'))[0]:
            mask = r[4]
            for cls, name in CLASSES.items():
                if mask == 1 << (cls - 1):
                    self.spell_class.setdefault(r[2], name)
        tabs = {r[0]: r[12] for r in dbc(os.path.join(dbc_dir, 'TalentTab.dbc'))[0]}
        self.talents = {}
        learnable = {int(r[0]) for r in query(mysql, 'SELECT spell FROM npc_trainer UNION SELECT spell FROM '
                                              'npc_trainer_template UNION SELECT Spell FROM playercreateinfo_spell')}
        for r in dbc(os.path.join(dbc_dir, 'Talent.dbc'))[0]:
            mask = tabs.get(r[1], 0)
            for spell in r[4:13]:
                if spell:
                    learnable.add(spell)
                    self.talents[spell] = True
                    for cls, name in CLASSES.items():
                        if mask == 1 << (cls - 1):
                            self.spell_class.setdefault(spell, name)
        # What the learnable spells teach, trigger and proc: the spells cast in play.
        self.triggered_by = {}
        known, todo = set(), list(learnable)
        while todo:
            spell = todo.pop()
            if spell in known or spell not in self.spells:
                continue
            known.add(spell)
            for e in self.spells[spell]['effects']:
                t = e['EffectTriggerSpell']
                if t and (e['Effect'] in (LEARN_SPELL, TRIGGER_SPELL)
                          or e['EffectApplyAuraName'] in (PROC_TRIGGER_SPELL, PERIODIC_TRIGGER_SPELL, ADD_TARGET_TRIGGER)):
                    todo.append(t)
                    self.triggered_by.setdefault(t, spell)
                    if spell in self.spell_class:
                        self.spell_class.setdefault(t, self.spell_class[spell])
        self.played = {s for s in known if any(e['Effect'] not in (0, LEARN_SPELL) for e in self.spells[s]['effects'])}

    def klass(self, spell):
        s = self.spells[spell]
        return self.spell_class.get(spell) or FAMILY_CLASS.get(s['SpellFamilyName']) or 'general'

    # --- the tooltip's numbers ---------------------------------------------------------------------------------
    def value(self, spell, i):
        e = self.spells[spell]['effects'][i]
        lo = e['EffectBasePoints'] + e['EffectBaseDice']
        hi = e['EffectBasePoints'] + e['EffectDieSides']
        return (lo, hi) if e['EffectDieSides'] > e['EffectBaseDice'] else (lo, lo)

    def duration_ms(self, spell):
        return self.durations.get(self.spells[spell]['DurationIndex'], (0, 0))[0]

    def var(self, spell, letter, i, divide=1):
        """The value of `$<letter><i>` in `spell`'s text, as text, or None."""
        s = self.spells.get(spell)
        if s is None:
            return None
        n = max(i - 1, 0)
        e = s['effects'][n]

        def num(x):
            x = abs(x) / divide
            return ('%d' % x) if float(x).is_integer() else ('%.1f' % x).rstrip('0').rstrip('.')
        if letter in 'sm':
            lo, hi = self.value(spell, n)
            return num(lo) if lo == hi or letter == 'm' else '%s to %s' % (num(lo), num(hi))
        if letter == 'o':
            amp = e['EffectAmplitude']
            ticks = self.duration_ms(spell) // amp if amp else 1
            lo, hi = self.value(spell, n)
            return num(lo * ticks) if lo == hi else '%s to %s' % (num(lo * ticks), num(hi * ticks))
        if letter == 't':
            return num(e['EffectAmplitude'] / 1000)
        if letter == 'd':
            ms = self.duration_ms(spell)
            if ms <= 0:
                return 'until cancelled'
            sec = ms / 1000
            return ('%s min' % num(sec / 60)) if sec >= 60 and sec % 60 == 0 else ('%s sec' % num(sec))
        if letter == 'h':
            return num(s['ProcChance'])
        if letter == 'n':
            return num(s['ProcCharges'])
        if letter == 'u':
            return num(s['StackAmount'])
        if letter == 'x':
            return num(e['EffectChainTarget'])
        if letter == 'a':
            return num(self.radii.get(e['EffectRadiusIndex'], 0))
        if letter == 'r':
            return num(self.ranges.get(s['RangeIndex'], 0))
        if letter == 'e':
            return num(e['EffectMultipleValue'])
        if letter == 'b':
            return num(e['EffectPointsPerComboPoint'])
        if letter == 'i':
            return num(s['MaxAffectedTargets'])
        return None

    def render(self, spell, text):
        def plural(m):
            return m.group(2)
        text = re.sub(r'\$[lL]([^:;]*):([^;]*);', plural, text)
        text = re.sub(r'\$[gG]([^:;]*):([^;]*);', lambda m: m.group(1) + '/' + m.group(2), text)

        def sub(m):
            divide = int(m.group(1)) if m.group(1) else 1
            other = int(m.group(2)) if m.group(2) else spell
            got = self.var(other, m.group(3).lower(), int(m.group(4) or 1), divide)
            return got if got is not None else m.group(0)
        text = re.sub(r'\$(?:/(\d+);)?(\d+)?([a-zA-Z])(\d)?', sub, text)
        return text.replace('\r', '').replace('\n', ' ').strip()


def main():
    split = sys.argv.index('--')
    data = Data(sys.argv[1:split], sys.argv[split + 1])
    effect_names, aura_names = enum_names('SpellEffect'), enum_names('AuraType')

    code = {}
    for path in glob.glob(os.path.join(SOURCE, '**', '*.d'), recursive=True):
        if not path.endswith('spellids.d'):
            code[os.path.relpath(path, REPO)] = open(path).read()
    real_tests = ''.join(t for p, t in code.items() if re.match(r'real(spell|classspell)tests\.d$|realclass_\w+\.d$', os.path.basename(p)))

    def where(ids):
        """The source files naming one of `ids` (as a number), but the real-data tests."""
        pattern = re.compile(r'(?<![\w.])(%s)(?![\w.])' % '|'.join(str(i) for i in ids))
        return sorted(os.path.basename(p) for p, t in code.items()
                      if not p.endswith('realspelltests.d') and pattern.search(t))

    def tested(ids):
        return bool(re.search(r'(?<![\w.])(%s)(?![\w.])' % '|'.join(str(i) for i in ids), real_tests))

    # One entry per spell name and class: its ranks together, described by the highest.
    groups = collections.defaultdict(list)
    for spell in data.played:
        groups[(data.klass(spell), data.spells[spell]['SpellName'])].append(spell)

    def needs(spell):
        """What in `spell` the server's own code must do (the data alone does not say)."""
        s = data.spells[spell]
        why = []
        for e in s['effects']:
            eff, aura = e['Effect'], e['EffectApplyAuraName']
            if eff == DUMMY:
                why.append('dummy effect')
            elif eff == SCRIPT_EFFECT:
                why.append('script effect')
            elif eff == SEND_EVENT:
                why.append('event %d' % e['EffectMiscValue'])
            if aura == AURA_DUMMY:
                why.append('dummy aura')
            elif aura == OVERRIDE_CLASS_SCRIPTS:
                why.append('class script %d' % e['EffectMiscValue'])
            elif aura in (PROC_TRIGGER_SPELL, PROC_TRIGGER_DAMAGE, ADD_TARGET_TRIGGER):
                why.append('proc')
            elif aura in (ADD_FLAT_MODIFIER, ADD_PCT_MODIFIER):
                why.append('modifies spells')
        if s['ProcFlags'] and 'proc' not in why:
            why.append('proc')
        if s['CasterAuraState'] or s['TargetAuraState']:
            why.append('aura state')
        return list(dict.fromkeys(why))

    def mechanics(spell):
        s = data.spells[spell]
        parts = []
        for e in s['effects']:
            if not e['Effect']:
                continue
            name = effect_names.get(e['Effect'], 'effect%d' % e['Effect'])
            if e['EffectApplyAuraName']:
                name += ' ' + aura_names.get(e['EffectApplyAuraName'], 'aura%d' % e['EffectApplyAuraName'])
            if e['EffectTriggerSpell']:
                name += ' -> %d' % e['EffectTriggerSpell']
            parts.append(name)
        return '; '.join(parts)

    def cooldown(spell):
        s = data.spells[spell]
        out = []
        if s['RecoveryTime']:
            out.append('own %gs' % (s['RecoveryTime'] / 1000))
        if s['CategoryRecoveryTime']:
            out.append('category %d: %gs' % (s['Category'], s['CategoryRecoveryTime'] / 1000))
        return ', '.join(out)

    os.makedirs(OUT, exist_ok=True)
    by_class = collections.defaultdict(list)
    for (klass, name), ids in groups.items():
        by_class[klass].append((name, sorted(ids)))
    summary = []
    for klass in sorted(by_class):
        entries = sorted(by_class[klass])
        lines = ['# %s spells' % klass.capitalize(), '',
                 'Generated by tools/spellspec.py from the 1.12.1 client (Spell.dbc) and the world database: do not '
                 'edit. Each spell a %s can learn (or that one of them casts, procs or triggers), its tooltip with the '
                 'numbers of its highest rank, and what the data alone does not say. **code**: the source files that '
                 'name one of its ranks; **real test**: a test casts it on the real data '
                 '(source/dmangos/world/realspelltests.d, realclassspelltests.d, realclass_*.d).' % klass, '']
        scripted = done = coded = 0
        plain = []
        for name, ids in entries:
            top = max(ids, key=lambda i: (data.spells[i]['effects'][0]['EffectBasePoints'], i))
            ranked = [i for i in ids if data.text.get(i, ('', '', '', ''))[1].startswith('Rank')]
            top = max(ranked, key=lambda i: int(re.sub(r'\D', '', data.text[i][1]) or 0)) if ranked else top
            _, rank, desc, tip = data.text.get(top, ('', '', '', ''))
            why = list(dict.fromkeys(w for i in ids for w in needs(i)))
            if not why:
                plain.append((name, ids, data.render(top, desc)))
                continue
            scripted += 1
            files = where(ids)
            real = tested(ids)
            coded += bool(files)
            done += real
            mark = 'tested on the real data' if real else 'untested'
            lines.append('## %s (%s)' % (name, mark))
            lines.append('')
            lines.append('- ids: %s%s' % (', '.join(str(i) for i in ids),
                                          ' (triggered by %d)' % data.triggered_by[ids[0]] if ids[0] in data.triggered_by else ''))
            if desc:
                lines.append('- tooltip (%s): %s' % (rank or 'no rank', data.render(top, desc)))
            if tip:
                lines.append('- aura: %s' % data.render(top, tip))
            lines.append('- needs code for: %s' % ', '.join(why))
            lines.append('- effects (%d): %s' % (top, mechanics(top)))
            cd = cooldown(top)
            if cd:
                lines.append('- cooldown: %s' % cd)
            s = data.spells[top]
            if s['ProcFlags'] or s['ProcChance'] not in (0, 101) or s['ProcCharges']:
                lines.append('- proc: flags 0x%x, chance %d%%, charges %d' % (s['ProcFlags'], s['ProcChance'], s['ProcCharges']))
            if s['SpellFamilyFlags']:
                lines.append('- family %d, flags 0x%x' % (s['SpellFamilyName'], s['SpellFamilyFlags']))
            lines.append('- code: %s' % (', '.join(files) if files else '-'))
            lines.append('')
        lines.append('## Done by the data alone')
        lines.append('')
        lines.append('Their effects and auras are the generic ones the server does for every spell.')
        lines.append('')
        for name, ids, desc in plain:
            lines.append('- **%s** (%s): %s' % (name, ', '.join(str(i) for i in ids), desc or '-'))
        open(os.path.join(OUT, klass + '.md'), 'w').write('\n'.join(lines) + '\n')
        summary.append((klass, len(entries), scripted, coded, done))

    index = ['# What the spells are supposed to do', '',
             'Generated by tools/spellspec.py: do not edit. The 1.12.1 client\'s own tooltip for every spell a player '
             'can learn (and what they cast in turn), and of those the data alone does not do, whether the server\'s '
             'code names them and whether a test casts them on the real data. The tooltip is the specification: '
             'what the server does must agree with it.', '',
             '| class | spells | need code | named in code | tested on the real data |', '|---|---|---|---|---|']
    for klass, total, scripted, coded, done in summary:
        index.append('| [%s](%s.md) | %d | %d | %d | %d |' % (klass, klass, total, scripted, coded, done))
    open(os.path.join(OUT, 'README.md'), 'w').write('\n'.join(index) + '\n')
    for row in summary:
        print('%-8s %4d spells, %4d need code, %4d named in code, %4d tested' % row)


if __name__ == '__main__':
    sys.exit(main())
