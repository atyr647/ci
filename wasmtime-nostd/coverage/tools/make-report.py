#!/usr/bin/env python3
"""Turns the per-target summary.txt files of one coverage run into markdown tables.
usage: make-report.py <dir holding linux-x64/ linux-arm64/ mac-arm64/ win-x64/ win-arm64/> [<dir holding link-*/>]"""
import re, sys, os
root = sys.argv[1]
targets = ['linux-x64', 'linux-arm64', 'mac-arm64', 'win-x64', 'win-arm64']
S = {}
for t in targets:
    p = os.path.join(root, t, 'summary.txt')
    S[t] = open(p, errors='replace').read().splitlines() if os.path.exists(p) else []

def find(t, prefix):
    return [l for l in S[t] if l.startswith(prefix)]

def counts(line):
    m = re.search(r'SUMMARY (?:tests=(\d+) )?pass=(\d+) fail=(\d+)', line)
    if m:
        total = m.group(1) or str(int(m.group(2)) + int(m.group(3)))
        return f'{m.group(2)}/{total}'
    m = re.search(r'rc=(\d+)\s+(.*)', line)
    return ('rc=' + m.group(1) + ' ' + m.group(2)[:60]) if m else line[:60]

def row(label, prefixes, join=' / '):
    cells = []
    for t in targets:
        parts = []
        for pre in prefixes:
            ls = find(t, pre)
            parts.append(counts(ls[0]) if ls else 'n/a')
        cells.append(join.join(parts))
    return f'| {label} | ' + ' | '.join(cells) + ' |'

print('| suite (native signals / native explicit checks / Pulley) | ' + ' | '.join(targets) + ' |')
print('|---|' + '---|' * len(targets))
for name, key in [('GC (struct, array, i31, casts, br_on_cast, call_ref, linked structures)', 'gc'), ('exceptions + tail calls', 'eh'), ('memory64 + multi-memory', 'mem'), ('relaxed SIMD', 'relaxed')]:
    print(row(name, [f'core {key} sig', f'core {key} nosig', f'core {key} pulley']))
print(row('GC collectors drc / null / copying (native signals)', ['gc-collector drc', 'gc-collector null', 'gc-collector copying']))
print(row('async: fibers (suspend, deep stack, trap after suspend, stack overflow on a fiber)', ['async sig', 'async nosig', 'async pulley']))
print(row('C++20 coroutines', ['coroutines sig', 'coroutines nosig', 'coroutines pulley']))
print(row('WASI preview 1, wasi-sdk program (58 checks incl. files, dirs, symlinks, clocks, random, poll, TCP)', ['wasi-p1 sig', 'wasi-p1 nosig', 'wasi-p1 pulley']))
print(row('WASI preview 2, same program as a component (53 checks, no sockets)', ['wasi-p2 sig', 'wasi-p2 nosig', 'wasi-p2 pulley']))
print(row('WASI preview 2 TCP loopback + name lookup', ['wasi-p2 sockets sig', 'wasi-p2 sockets pulley']))
print(row('component model canonical ABI (hand-written component)', ['component canonical-ABI selftest sig']))
print()
print('Other lines of the summaries (timings, exit codes, loader messages):')
for t in targets:
    print(f'\n### {t}')
    for l in S[t]:
        if l.startswith(('threads', 'wasi-p1 exit', 'host exit', 'same,', 'wasi-p1 base', 'async-timing', 'asyncify', 'coroutine-timing', 'gc-stress', 'wasi-p1 call', 'wasi-p2 call')):
            print('- ' + l[:700])
