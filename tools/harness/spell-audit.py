#!/usr/bin/env python3
"""The spells a player can learn, against what the world server does with them: fails if one of them has a spell
effect the server leaves undone, or applies an aura type the server's code never names, unless it is one of the
known ones in spell-audit-known.txt (each with its reason). So a gap like Sinister Strike's combo points (an effect
silently ignored) cannot come back unnoticed.

The learnable spells: those trainers teach (npc_trainer, npc_trainer_template: a "learn spell" effect's spell),
those a new character has (playercreateinfo_spell), every rank of every talent (Talent.dbc), and what any of them
triggers, procs or teaches in turn. Spells whose only effect teaches another are not cast in play and not counted.

    tools/harness/spell-audit.py MYSQL_COMMAND... -- DBC_DIR

MYSQL_COMMAND is a mariadb client invocation for the world database that takes `-B -N -e QUERY`.
"""
import glob, os, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, '..', '..', 'source', 'dmangos')
LEARN_SPELL, TRIGGER_SPELL = 36, 64
PROC_TRIGGER_SPELL, PERIODIC_TRIGGER_SPELL = 42, 23
# Effects that only matter as a spell is learned (a skill, a language, a proficiency), not as it is cast.
PASSIVE_EFFECTS = {'dualWield', 'proficiency', 'language', 'skill', 'skillStep', 'weapon', 'defense', 'block',
                   'parry', 'dodge', 'spellDefense', 'tradeSkill', 'learnSpell'}


def query(mysql, sql):
    out = subprocess.run(mysql + ['-B', '-N', '-e', sql], check=True, capture_output=True, text=True).stdout
    return [line.split('\t') for line in out.splitlines() if line]


def dbc_rows(path):
    data = open(path, 'rb').read()
    _, count, fields, size, _ = struct.unpack('<4s4I', data[:20])
    return [struct.unpack('<%dI' % fields, data[20 + i * size:20 + i * size + 4 * fields]) for i in range(count)]


def enum_names(name):
    text = open(os.path.join(SOURCE, 'world', 'spellids.d')).read()
    start = text.index('enum ' + name)
    body = text[start:text.index('}', start)]
    return {int(m.group(2)): m.group(1) for m in re.finditer(r'^\s*(\w+)\s*=\s*(\d+)', body, re.M)}


def main():
    split = sys.argv.index('--')
    mysql, dbc_dir = sys.argv[1:split], sys.argv[split + 1]
    spells = {}
    for row in query(mysql, 'SELECT Id, SpellName, Effect1, Effect2, Effect3, EffectApplyAuraName1, '
                     'EffectApplyAuraName2, EffectApplyAuraName3, EffectTriggerSpell1, EffectTriggerSpell2, '
                     'EffectTriggerSpell3 FROM spell_template'):
        spells[int(row[0])] = (row[1], [int(x) for x in row[2:5]], [int(x) for x in row[5:8]], [int(x) for x in row[8:11]])
    learnable = {int(r[0]) for r in query(mysql, 'SELECT spell FROM npc_trainer UNION SELECT spell FROM '
                                          'npc_trainer_template UNION SELECT Spell FROM playercreateinfo_spell')}
    for row in dbc_rows(os.path.join(dbc_dir, 'Talent.dbc')):
        learnable.update(s for s in row[4:13] if s)
    known, todo = set(), list(learnable)
    while todo:
        spell = todo.pop()
        if spell in known or spell not in spells:
            continue
        known.add(spell)
        _, effects, auras, triggers = spells[spell]
        for effect, aura, trigger in zip(effects, auras, triggers):
            if trigger and (effect in (LEARN_SPELL, TRIGGER_SPELL) or aura in (PROC_TRIGGER_SPELL, PERIODIC_TRIGGER_SPELL)):
                todo.append(trigger)
    played = [s for s in known if any(e not in (0, LEARN_SPELL) for e in spells[s][1])]

    effect_names, aura_names = enum_names('SpellEffect'), enum_names('AuraType')
    # The effects no caster's cast does: the list the effect switch is checked against (`notDoneByAny`).
    effects_code = open(os.path.join(SOURCE, 'world', 'spelleffects.d')).read()
    start = effects_code.index('notDoneByAny = [')
    undone_block = effects_code[start:effects_code.index('];', start)]
    undone = set(re.findall(r'SpellEffect\.(\w+)', undone_block))
    code = ''
    for path in glob.glob(os.path.join(SOURCE, '**', '*.d'), recursive=True):
        if not path.endswith('spellids.d'):
            code += open(path).read()
    named = set(re.findall(r'AuraType\.(\w+)', code))

    found = {}
    for spell in played:
        name, effects, auras, _ = spells[spell]
        for effect in effects:
            n = effect_names.get(effect, 'effect%d' % effect)
            if effect and n in undone and n not in PASSIVE_EFFECTS:
                found.setdefault('effect ' + n, set()).add(name)
        for aura in auras:
            n = aura_names.get(aura, 'aura%d' % aura)
            if aura and n not in named:
                found.setdefault('aura ' + n, set()).add(name)

    allowed = {}
    for line in open(os.path.join(HERE, 'spell-audit-known.txt')):
        line = line.strip()
        if line and not line.startswith('#'):
            key, _, reason = line.partition(':')
            allowed[key.strip()] = reason.strip()
    new = sorted(k for k in found if k not in allowed)
    print('%d learnable spells cast in play; %d known gaps (spell-audit-known.txt)' % (len(played), len(allowed)))
    for key in new:
        print('NOT DONE: %s (%s)' % (key, ', '.join(sorted(found[key])[:6])))
    for key in sorted(k for k in allowed if k not in found):
        print('done now, take it off spell-audit-known.txt: ' + key)
    return 1 if new else 0


if __name__ == '__main__':
    sys.exit(main())
