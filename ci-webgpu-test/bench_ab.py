#!/usr/bin/env python3
"""Runs several builds of ci-webgpu-test/dawn_bench.cpp interleaved (round 1: A B C, round 2: A B C ...) on the same machine, takes the median of each metric over the rounds
and prints a table with ratios against the first variant. Interleaving keeps slow drifts of a shared CI machine (other tenants, thermal state) from favouring one build.
usage: bench_ab.py --rounds N [--env K=V]... --variant "name|K=V,K2=V2|command with args" [--variant ...]   (first variant is the reference)"""
import argparse, json, os, platform, re, statistics, subprocess, sys, time
ap = argparse.ArgumentParser(); ap.add_argument('--rounds', type=int, default=5); ap.add_argument('--variant', action='append', default=[]); ap.add_argument('--timeout', type=int, default=400)
ap.add_argument('--json', default='bench-results.json'); ap.add_argument('--title', default='')
a = ap.parse_args()
variants = []
for v in a.variant:
    name, env, cmd = v.split('|', 2)
    variants.append((name, dict(kv.split('=', 1) for kv in env.split(',') if kv), cmd))
HIGHER_BETTER = ('GB/s', 'MB/s', 'GFLOP/s')
samples = {n: {} for n, _, _ in variants}; units = {}; adapters = {}; failures = {n: [] for n, _, _ in variants}
def machine():
    cpu = platform.processor() or ''
    try:
        if sys.platform.startswith('linux'): cpu = re.search(r'model name\s*:\s*(.*)', open('/proc/cpuinfo').read()).group(1)
        elif sys.platform == 'darwin': cpu = subprocess.run(['sysctl', '-n', 'machdep.cpu.brand_string'], capture_output=True, text=True).stdout.strip()
    except Exception: pass
    return f'{platform.system()} {platform.release()} {platform.machine()}, {os.cpu_count()} logical CPUs, {cpu}'
for r in range(a.rounds):
    order = variants if r % 2 == 0 else list(reversed(variants))   # alternate who goes first
    for name, env, cmd in order:
        e = dict(os.environ); e.update(env)
        t0 = time.time()
        try:
            p = subprocess.run(cmd, shell=True, env=e, capture_output=True, text=True, timeout=a.timeout)
            out = p.stdout + p.stderr; rc = p.returncode
        except subprocess.TimeoutExpired as x:
            out = (x.stdout or b'').decode(errors='replace') if isinstance(x.stdout, bytes) else (x.stdout or ''); rc = 124
        got = 0
        for m in re.finditer(r'^BENCH (\S+) (\S+) (\S+)\s*$', out, re.M):
            samples[name].setdefault(m.group(1), []).append(float(m.group(2))); units[m.group(1)] = m.group(3); got += 1
        for m in re.finditer(r'^adapter: (.*)$', out, re.M): adapters[name] = m.group(1)
        print(f'round {r + 1}/{a.rounds} {name:14s} exit={rc} metrics={got} wall={time.time() - t0:.1f}s', flush=True)
        if rc != 0 or got == 0:
            failures[name].append('\n'.join(out.replace('\r', '').splitlines()[-12:]))
metrics = []
for v in variants:
    for k in samples[v[0]]:
        if k not in metrics: metrics.append(k)
ref = variants[0][0]
lines = [f'### {a.title}' if a.title else '### Dawn benchmark', f'machine: {machine()}', f'rounds: {a.rounds} (interleaved), value = median over rounds', '']
for n, _, _ in variants: lines.append(f'- **{n}**: adapter `{adapters.get(n, "?")}`')
lines += ['', '| metric | unit | ' + ' | '.join(n for n, _, _ in variants) + ' | ' + ' | '.join(f'{n} / {ref}' for n, _, _ in variants[1:]) + ' |', '|---|---|' + '---|' * (len(variants) + len(variants) - 1)]
result = {'machine': machine(), 'rounds': a.rounds, 'adapters': adapters, 'metrics': {}}
for k in metrics:
    med = {}
    for n, _, _ in variants:
        s = samples[n].get(k); med[n] = statistics.median(s) if s else None
    result['metrics'][k] = {'unit': units[k], 'median': med, 'all': {n: samples[n].get(k) for n, _, _ in variants}}
    cells = []
    for n, _, _ in variants: cells.append('-' if med[n] is None else f'{med[n]:.4g}')
    ratios = []
    for n, _, _ in variants[1:]:
        if med[n] is None or not med[ref]: ratios.append('-'); continue
        x = med[n] / med[ref]
        # "speed": above 1.00 always means this variant is faster than the reference
        sp = x if units[k] in HIGHER_BETTER else 1 / x if x else 0
        ratios.append(f'{sp:.2f}x')
    lines.append(f'| {k} | {units[k]} | ' + ' | '.join(cells) + ' | ' + ' | '.join(ratios) + ' |')
lines += ['', f'ratio columns are SPEED relative to `{ref}`: above 1.00x = faster than `{ref}`, below = slower (time metrics inverted).']
for n, f in failures.items():
    if f: lines += ['', f'`{n}` had {len(f)} failing round(s); last output:', '```', f[-1], '```']
text = '\n'.join(lines); print('\n' + text)
if os.environ.get('GITHUB_STEP_SUMMARY'): open(os.environ['GITHUB_STEP_SUMMARY'], 'a').write(text + '\n')
json.dump(result, open(a.json, 'w'), indent=1)
sys.exit(0 if all(samples[n] for n, _, _ in variants) else 1)
