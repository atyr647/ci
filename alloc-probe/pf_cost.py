#!/usr/bin/env python3
"""First burst of buffer creation: how many page faults, how much time, and are transparent huge pages involved?
usage: pf_cost.py <label> <reps> -- <cmd...>   (the command must honour BENCH_BUFFER_REPEAT=N: N create+release calls, then exit)
Per N in {1, 4000} runs the command <reps> times and reports the median of: process minor faults, thp_fault_alloc delta (system wide counter, runner is otherwise idle), loop time.
The cost of the burst is what N=4000 has more than N=1."""
import os, re, statistics, subprocess, sys, resource
def vm(k):
    for l in open('/proc/vmstat'):
        a = l.split()
        if a[0] == k: return int(a[1])
    return 0
def run(cmd, n, env):
    e = dict(os.environ, BENCH_BUFFER_REPEAT=str(n), WGT_BACKEND='vulkan', **env)
    t0 = vm('thp_fault_alloc'); r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    p = subprocess.run(cmd, env=e, capture_output=True, text=True)
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN); t1 = vm('thp_fault_alloc')
    m = re.search(r'buffer_create_release_us\D+([0-9.]+)', p.stdout + p.stderr)
    return (r1.ru_minflt - r0.ru_minflt, t1 - t0, float(m.group(1)) * n / 1000.0 if m else float('nan'), p.returncode)
def main():
    label, reps = sys.argv[1], int(sys.argv[2]); cmd = sys.argv[4:]
    env = {}
    for kv in os.environ.get('PF_ENV', '').split():
        k, v = kv.split('=', 1); env[k] = v
    res = {}
    for n in (1, 4000):
        rows = [run(cmd, n, env) for _ in range(reps)]
        bad = [r for r in rows if r[3] != 0]
        res[n] = (statistics.median(r[0] for r in rows), statistics.median(r[1] for r in rows), statistics.median(r[2] for r in rows), len(bad))
    print(f"PF {label:28s} faults N=1 {res[1][0]:.0f}  N=4000 {res[4000][0]:.0f}  burst {res[4000][0]-res[1][0]:.0f} faults ({(res[4000][0]-res[1][0])*4/1024:.2f} MiB)"
          f" | thp_fault_alloc N=1 {res[1][1]:.0f} N=4000 {res[4000][1]:.0f} | loop ms N=4000 {res[4000][2]:.2f} (N=1 {res[1][2]:.3f}) | failed runs {res[1][3]+res[4000][3]}")
main()
