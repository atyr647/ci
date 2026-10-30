#!/usr/bin/env python3
"""Interleaved A/B of the same wasm kernels under several runtimes on one machine. usage: ab.py <rounds> "name|command" ...   prints best-of-rounds ms per kernel and the speed relative to the first variant."""
import re, statistics, subprocess, sys, os
rounds = int(sys.argv[1]); variants = [v.split('|', 1) for v in sys.argv[2:]]
best = {}; sums = {}; failed = {}
for r in range(rounds):
    for name, cmd in (variants if r % 2 == 0 else list(reversed(variants))):
        try: out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=900).stdout
        except Exception as e: out = ''
        got = 0
        for m in re.finditer(r'^KERNEL (\S+) (\S+) (\d+)', out, re.M):
            k = (name, m.group(1)); best[k] = min(best.get(k, 1e30), float(m.group(2))); sums.setdefault(m.group(1), set()).add(m.group(3)); got += 1
        if not got: failed[name] = failed.get(name, 0) + 1
kernels = ['matmul256', 'nbody1024', 'interp', 'triad32MB', 'hash16MB', 'sort1M', 'transform']
ref = variants[0][0]
lines = ['| runtime | ' + ' | '.join(kernels) + ' |', '|---|' + '---|' * len(kernels)]
for name, _ in variants:
    cells = []
    for k in kernels:
        if (name, k) not in best: cells.append('-'); continue
        rel = '' if name == ref or (ref, k) not in best else f' ({best[(ref, k)] / best[(name, k)]:.2f}x)'
        cells.append(f'{best[(name, k)]:.2f}{rel}')
    lines.append(f'| {name} | ' + ' | '.join(cells) + ' |')
lines.append(''); lines.append(f'ms, best of {rounds} interleaved rounds; (x) = speed relative to `{ref}`, above 1.00 is faster. checksums identical across runtimes: ' + ('yes' if all(len(s) == 1 for s in sums.values()) else 'NO ' + str(sums)))
if failed: lines.append('rounds without output: ' + str(failed))
text = '\n'.join(lines); print(text)
if os.environ.get('GITHUB_STEP_SUMMARY'): open(os.environ['GITHUB_STEP_SUMMARY'], 'a').write('### ' + os.environ.get('AB_TITLE', 'runtime comparison') + '\n' + text + '\n')
