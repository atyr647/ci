#!/usr/bin/env python3
"""From a linker map made with --cref: which symbols defined in objects matching <substring> are referenced from OTHER objects, and by whom.
usage: whopulls.py <map> <substring-of-defining-object> [max]"""
import sys, re, collections
mp, sub = sys.argv[1], sys.argv[2]; mx = int(sys.argv[3]) if len(sys.argv) > 3 else 40
txt = open(mp, errors='replace').read()
i = txt.find('Cross Reference Table')
lines = txt[i:].split('\n')[3:]
cur = None; ent = []
for l in lines:
    if not l.strip(): continue
    if l[0] != ' ':
        parts = l.split(None, 1)
        cur = [parts[0], []]; ent.append(cur)
        if len(parts) > 1: cur[1].append(parts[1].strip())
    elif cur: cur[1].append(l.strip())
hits = collections.defaultdict(set)
for sym, files in ent:
    if not files or sub not in files[0]: continue
    for f in files[1:]:
        if sub not in f: hits[f].add(sym)
rank = sorted(hits.items(), key=lambda kv: -len(kv[1]))
print(f'{len(rank)} other objects reference symbols defined in *{sub}*')
for f, syms in rank[:mx]: print(f'- {f}: {len(syms)} symbols, e.g. {sorted(syms)[0][:120]}')
