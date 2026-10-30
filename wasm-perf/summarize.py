#!/usr/bin/env python3
"""summarize.py FILE.md [...]  -- for every 'ms per kernel' table in the result files: best wasm row vs best native row per kernel, and vs the native baseline-ISA scalar row.
Rows are classified by their name prefix: 'native ...' = native, 'wasmtime ...' = Wasmtime (the engine rows other tools add are listed separately by --all)."""
import re, sys
def tables(text):
    out = []; cur = None
    for line in text.splitlines():
        if 'ms per kernel' in line: cur = {'title': line.strip('# ').split(':')[0], 'cols': None, 'rows': {}}; out.append(cur); continue
        if cur is None: continue
        if line.startswith('| config') and cur['cols'] is None: cur['cols'] = [c.strip() for c in line.strip('|').split('|')][1:]; continue
        if line.startswith('|---'): continue
        if line.startswith('|') and cur['cols'] and 'FAILED' not in line:
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if len(cells) == len(cur['cols']) + 1:
                try: cur['rows'][cells[0]] = [float(c) if c not in ('-', '') else None for c in cells[1:]]
                except ValueError: pass
        elif cur['cols'] and line.strip() == '': 
            if cur['rows']: cur = None
    return out
for path in sys.argv[1:]:
    for t in tables(open(path).read()):
        nat = {k: v for k, v in t['rows'].items() if k.startswith('native ')}; wt = {k: v for k, v in t['rows'].items() if k.startswith('wasmtime ')}
        if not nat or not wt: continue
        print(f'### {path.split("/")[-1]} :: {t["title"]}'); print('| kernel | best native (ms) | best wasmtime (ms) | wasm as % of best native | native baseline scalar (ms) | wasm as % of baseline scalar |'); print('|---|---|---|---|---|---|')
        base = next((k for k in nat if k.endswith('n-scalar') or k.endswith('cc-scalar-O3')), None)
        for i, c in enumerate(t['cols']):
            nb = min(((v[i], k) for k, v in nat.items() if v[i]), default=None); wb = min(((v[i], k) for k, v in wt.items() if v[i]), default=None)
            if not nb or not wb: continue
            bs = nat[base][i] if base and nat[base][i] else None
            print(f'| {c} | {nb[0]:.2f} ({nb[1][7:]}) | {wb[0]:.2f} ({wb[1][9:]}) | {100 * nb[0] / wb[0]:.0f}% | ' + (f'{bs:.2f} | {100 * bs / wb[0]:.0f}%' if bs else '- | -') + ' |')
        print()
