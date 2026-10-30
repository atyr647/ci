#!/usr/bin/env python3
"""Interleaved benchmark runner for the shootout binaries.

usage: runner.py SPEC.json [--rounds N] [--ref NAME] [--kernels a,b,c] [--title T]
SPEC.json: [{"name": "...", "cmd": "shell command printing 'KERNEL <name> <ms> <checksum>' lines"}, ...]
Every command gets the kernel filter appended as its last argument. Rounds are interleaved (order reversed every other round)
and the best time per (row, kernel) is kept. Prints a markdown table of ms, a table of speed relative to the reference row
(above 1.00 = faster than the reference) and flags rows whose checksum differs from the reference row's checksum.
A row whose command fails or prints nothing is reported with the first stderr line, never silently dropped.
"""
import json, os, re, subprocess, sys

def main():
    a = sys.argv[1:]
    spec = json.load(open(a[0]))
    opt = {'--rounds': '3', '--ref': spec[0]['name'], '--kernels': 'matmul256,nbody1024,transform', '--title': 'results'}
    for i in range(1, len(a) - 1, 2):
        opt[a[i]] = a[i + 1]
    rounds = int(opt['--rounds']); ref = opt['--ref']; kernels = opt['--kernels'].split(','); title = opt['--title']
    best, cks, errs = {}, {}, {}
    order = [s['name'] for s in spec]; cmds = {s['name']: s['cmd'] for s in spec}
    for rnd in range(rounds):
        for name in (order if rnd % 2 == 0 else list(reversed(order))):
            try:
                r = subprocess.run(cmds[name] + ' ' + ','.join(kernels), shell=True, capture_output=True, text=True, timeout=600)
            except Exception as e:
                errs[name] = 'timeout/exception ' + str(e)[:80]; continue
            got = 0
            for m in re.finditer(r'^KERNEL (\S+) (\S+) (\d+)', r.stdout, re.M):
                k = (name, m.group(1)); t = float(m.group(2)); got += 1
                if t < best.get(k, 1e30): best[k] = t
                cks.setdefault(k, set()).add(m.group(3))
            if not got:
                errs[name] = ((r.stderr or r.stdout).strip().splitlines() or ['no output'])[0][:140]
    ms = [f'### {title}: ms per kernel (best of {rounds} interleaved rounds)', '', '| config | ' + ' | '.join(kernels) + ' |', '|---|' + '---|' * len(kernels)]
    sp = ['', f'speed relative to `{ref}` (above 1.00 = faster); `!` = checksum differs from the reference row', '', '| config | ' + ' | '.join(kernels) + ' |', '|---|' + '---|' * len(kernels)]
    for n in order:
        if n in errs and not any((n, k) in best for k in kernels):
            ms.append(f'| {n} | ' + ' | '.join(['-'] * len(kernels)) + f' |  <- FAILED: {errs[n]}'); sp.append(f'| {n} | ' + ' | '.join(['-'] * len(kernels)) + ' |'); continue
        ms.append(f'| {n} | ' + ' | '.join(f'{best[(n, k)]:.2f}' if (n, k) in best else '-' for k in kernels) + ' |')
        cells = []
        for k in kernels:
            if (n, k) in best and (ref, k) in best:
                bad = '' if cks.get((n, k)) == cks.get((ref, k)) else '!'
                cells.append(f'{best[(ref, k)] / best[(n, k)]:.2f}{bad}')
            else:
                cells.append('-')
        sp.append(f'| {n} | ' + ' | '.join(cells) + ' |')
    text = '\n'.join(ms + sp)
    print(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        open(os.environ['GITHUB_STEP_SUMMARY'], 'a').write(text + '\n\n')

main()
