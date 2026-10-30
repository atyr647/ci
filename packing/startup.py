#!/usr/bin/env python3
"""Linux only. Start-up cost of a command with the page cache warm and cold, how many KiB the kernel read from disk (pgpgin), and what part of the process's memory is file-backed
(shared, clean, paged in on demand) versus anonymous.   usage: startup.py <label> <runs> -- <command...>   (needs sudo for drop_caches)"""
import sys, os, time, subprocess, statistics, re, shutil
label, runs = sys.argv[1], int(sys.argv[2]); cmd = sys.argv[sys.argv.index('--') + 1:]
def pgpgin():
    for l in open('/proc/vmstat'):
        if l.startswith('pgpgin '): return int(l.split()[1])
def drop():
    subprocess.run(['sync']); subprocess.run(['sudo', 'sh', '-c', 'echo 3 > /proc/sys/vm/drop_caches'], check=True); time.sleep(0.3)
def run_once():
    a = pgpgin(); t = time.perf_counter()
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    dt = time.perf_counter() - t; time.sleep(0.05)
    global last_out; last_out = p.stdout.decode(errors='replace')
    return dt * 1000, pgpgin() - a, p.returncode
def stat(v): return f'median {statistics.median(v):.1f} min {min(v):.1f} max {max(v):.1f}'
subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)   # first run installs the APE loader if needed
last_out = ''
warm = [run_once() for _ in range(runs)]
print('STARTUP', label, 'output of a run:', ' | '.join(last_out.strip().splitlines()[-3:])[:260])
cold = []
for _ in range(runs):
    drop(); cold.append(run_once())
print(f'STARTUP {label} warm ms: {stat([w[0] for w in warm])}; rc={set(w[2] for w in warm)}')
print(f'STARTUP {label} cold ms: {stat([c[0] for c in cold])}; read from disk KiB: {stat([c[1] for c in cold])}; rc={set(c[2] for c in cold)}')
# memory split: poll /proc/<pid>/smaps while the command runs and keep the snapshot with the largest total
best = None
exe = os.path.abspath(cmd[-1]) if os.path.exists(cmd[-1]) else None
for _ in range(3):
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); snap = None
    while p.poll() is None:
        try:
            txt = open(f'/proc/{p.pid}/smaps').read()
        except Exception:
            time.sleep(0.002); continue
        tot = {'Rss': 0, 'Pss': 0, 'Private_Dirty': 0, 'Private_Clean': 0, 'Shared_Clean': 0, 'Anonymous': 0, 'file_Rss': 0, 'exe_Rss': 0, 'exe_size': 0}
        cur = None; per = {}
        for l in txt.split('\n'):
            m = re.match(r'^[0-9a-f]+-[0-9a-f]+ \S+ \S+ \S+ \S+\s*(.*)$', l)
            if m: cur = m.group(1); continue
            m = re.match(r'^(\w+):\s+(\d+) kB', l)
            if not m: continue
            k, v = m.group(1), int(m.group(2))
            if k in tot: tot[k] += v
            if k in ('Rss', 'Size') and cur is not None:
                per.setdefault(cur or '[anon]', {'Rss': 0, 'Size': 0})[k] += v
            if k == 'Rss' and cur and cur.startswith('/'): tot['file_Rss'] += v
            if k == 'Rss' and cur and exe and os.path.basename(cur) == os.path.basename(exe): tot['exe_Rss'] += v
            if k == 'Size' and cur and exe and os.path.basename(cur) == os.path.basename(exe): tot['exe_size'] += v
        tot['top'] = sorted(((n, d['Rss'], d['Size']) for n, d in per.items()), key=lambda x: -x[1])[:6]
        if snap is None or tot['Rss'] >= snap['Rss']: snap = tot
        time.sleep(0.003)
    if snap and (best is None or snap['Rss'] > best['Rss']): best = snap
print(f'STARTUP {label} memory (kB, largest snapshot while running): {best}')
