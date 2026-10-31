#!/usr/bin/env python3
"""Pivot the output of guest/kern.c: kern-table.py <label>=<file> ...   (each file: output of `wn kern`, run one or more times; the fastest value per entry is used)."""
import re, sys
cfgs = []
for a in sys.argv[1:]:
    label, f = a.split('=', 1); d = {}; chk = {}; head = []
    for l in open(f, errors='replace').read().splitlines():
        m = re.match(r'K (\w+) (\S+) (\d+) ([\d.]+)', l)
        if m: k = (m.group(1), int(m.group(3)), m.group(2)); d[k] = min(d.get(k, 1e30), float(m.group(4)))
        m = re.match(r'C (\w+) (\d+) (\S+) (\S+)', l)
        if m: chk[(m.group(1), int(m.group(2)))] = (m.group(3), m.group(4))
        if l.startswith('host : module level') or l.startswith('native level'): head.append(l.strip())
    cfgs.append((label, d, chk, sorted(set(head))))
for label, d, chk, head in cfgs:
    print(f'### {label}   [{" | ".join(head)}]')
    print('| op | size | scalar us | wasm SIMD128 us | native us | native vs wasm | native vs scalar | max error wasm/native, scalar/native |')
    print('|---|---|---|---|---|---|---|---|')
    keys = sorted({(o, n) for (o, n, _) in d}, key=lambda t: (t[0], t[1]))
    for o, n in keys:
        s, w, nat = d.get((o, n, 'scalar')), d.get((o, n, 'wasm-simd128')), d.get((o, n, 'native'))
        if not (s and w and nat): continue
        e = chk.get((o, n), ('-', '-'))
        print(f'| {o} | {n} | {s:.3f} | {w:.3f} | {nat:.3f} | {w / nat:.2f}x | {s / nat:.2f}x | {e[0]} / {e[1]} |')
    print()
