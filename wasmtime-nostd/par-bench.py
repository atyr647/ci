#!/usr/bin/env python3
"""Scaling of the parallel kernel (guest/par.c) with 1, 2, 4 threads under several runtimes, interleaved, best of N rounds.
usage: par-bench.py <rounds> "name|command with {n} for the thread count" ...   (commands print "KERNEL par<n> <ms> <checksum>")"""
import re, shlex, subprocess, sys, os
rounds = int(sys.argv[1]); variants = [v.split('|', 1) for v in sys.argv[2:]]; ns = (1, 2, 4)
best = {}; sums = {}; failed = {}
for r in range(rounds):
    for n in ns:
        for name, cmd in (variants if (r + n) % 2 == 0 else list(reversed(variants))):
            try: res = subprocess.run(shlex.split(cmd.replace('{n}', str(n))), capture_output=True, text=True, timeout=300); out = res.stdout
            except Exception as e: out = ''
            m = re.search(r'^KERNEL par(\d+) (\S+) (\d+)', out, re.M)
            if not m or int(m.group(1)) != n: failed[(name, n)] = failed.get((name, n), 0) + 1; continue
            k = (name, n); best[k] = min(best.get(k, 1e30), float(m.group(2))); sums.setdefault(name, set()).add(m.group(3))
lines = [f'| runtime | 1 thread ms | 2 threads ms | 4 threads ms | speedup 2 | speedup 4 |', '|---|---|---|---|---|---|']
for name, _ in variants:
    cells = [f'{best[(name, n)]:.1f}' if (name, n) in best else '-' for n in ns]
    sp = [f'{best[(name, 1)] / best[(name, n)]:.2f}x' if (name, 1) in best and (name, n) in best else '-' for n in (2, 4)]
    lines.append(f'| {name} | ' + ' | '.join(cells) + ' | ' + ' | '.join(sp) + ' |')
allsums = set().union(*sums.values()) if sums else set()
lines += ['', f'best of {rounds} interleaved rounds; cores visible: {os.cpu_count()}; checksum identical across runtimes and thread counts: ' + ('yes (' + next(iter(allsums)) + ')' if len(allsums) == 1 else 'NO ' + str(sums))]
if failed: lines.append('runs without a result: ' + str(failed))
text = '\n'.join(lines); print(text)
if os.environ.get('GITHUB_STEP_SUMMARY'): open(os.environ['GITHUB_STEP_SUMMARY'], 'a').write('### ' + os.environ.get('AB_TITLE', 'thread scaling') + '\n' + text + '\n')
