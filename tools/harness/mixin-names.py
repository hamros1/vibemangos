#!/usr/bin/env python3
"""Names defined twice in Character: in its own body and in one of the mixin templates it mixes in, or in two
of them. D resolves such a name silently (the class's own member hides a mixin's; two mixins' members make a
call ambiguous only where it is made), so a second definition can drift from the first unnoticed.

    python3 tools/harness/mixin-names.py      (exit status 1 if any name is defined twice)
"""
import glob, re, sys, os

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'source', 'dmangos', 'world')
DECL = re.compile(r'^    (?!return|if|else|foreach|while|switch|case|import|enum |alias |mixin |static assert|//|/\*|\*)'
                  r'(?:@\w+(?:\([^)]*\))? )*(?:(?:public|private|package|protected|static|final|override|abstract|'
                  r'const|immutable|shared|nothrow|pure|@safe|@trusted|@property|ref|auto) )*'
                  r'[\w!().\[\]*, ]+? (\w+)\s*\(', re.M)

def strip(text):
    """`text` with comments, string and character literals blanked (their braces would miscount the nesting)."""
    out, i, n = [], 0, len(text)
    while i < n:
        c, two = text[i], text[i:i + 2]
        if two == '//':
            j = text.find('\n', i); j = n if j < 0 else j; out.append(' ' * (j - i)); i = j
        elif two in ('/*', '/+'):
            end = '*/' if two == '/*' else '+/'
            j = text.find(end, i + 2); j = n if j < 0 else j + 2
            out.append(re_keep_newlines(text[i:j])); i = j
        elif c in '"`':
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if (c == '"' and text[j] == '\\') else 1
            out.append(c + re_keep_newlines(text[i + 1:j]) + c); i = j + 1
        elif c == "'" and i + 2 < n and (text[i + 2] == "'" or (text[i + 1] == '\\' and text[i + 3] == "'")):
            j = text.index("'", i + 2 if text[i + 1] != '\\' else i + 3) + 1
            out.append(' ' * (j - i)); i = j
        else:
            out.append(c); i += 1
    return ''.join(out)

def re_keep_newlines(s):
    return ''.join('\n' if ch == '\n' else ' ' for ch in s)

def body_of(text, start):
    """The text of the brace block that starts at or after `start`."""
    i = text.index('{', start); depth = 0
    for k in range(i, len(text)):
        depth += {'{': 1, '}': -1}.get(text[k], 0)
        if depth == 0:
            return text[i + 1:k]
    return text[i + 1:]

def members(block):
    # only the block's own level: drop nested blocks before matching
    flat, depth = [], 0
    for line in block.split('\n'):
        if depth == 0:
            flat.append(line)
        depth += line.count('{') - line.count('}')
    return set(DECL.findall('\n'.join(flat))) - KEYWORDS

# Not names: what the declaration pattern can catch in `const(T)* f(` or `void delegate(...) field`.
KEYWORDS = {'const', 'immutable', 'shared', 'inout', 'scope', 'delegate', 'function', 'ref', 'auto'}
# Defined twice on purpose: overloads with different parameters, which D merges into one overload set.
OVERLOADS = {'conditionMet'}  # (uint) in LootHandlers, (uint, Npc) in NpcHandlers

character = strip(open(os.path.join(root, 'character.d')).read())
cls = body_of(character, character.index('final class Character'))
mixed = re.findall(r'^    mixin (\w+)(?:!\([^)]*\))?;', cls, re.M)
templates = {}
for f in glob.glob(os.path.join(root, '*.d')):
    text = strip(open(f).read())
    for m in re.finditer(r'^mixin template (\w+)\(\)', text, re.M):
        templates[m.group(1)] = members(body_of(text, m.end()))
own = members(cls)
problems = []
seen = {}
for name in mixed:
    for member in templates.get(name, ()):
        if member in own:
            problems.append('%s: defined in Character and in its mixin %s' % (member, name))
        if member in seen and seen[member] != name and member not in OVERLOADS:
            problems.append('%s: defined in the mixins %s and %s' % (member, seen[member], name))
        seen.setdefault(member, name)
for p in sorted(set(problems)):
    print(p)
print('%d mixins, %d names checked: %s' % (len(mixed), len(seen) + len(own), 'none twice' if not problems else '%d twice' % len(set(problems))))
sys.exit(1 if problems else 0)
