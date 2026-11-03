#!/usr/bin/env python3
"""usage: pf_diff.py <label> <perf> -- <cmd...>
Runs the command with BENCH_BUFFER_REPEAT=1 and =4000 under `perf record -e page-faults -c 1 -d` and under `strace -f -e trace=memory`;
prints what the 4000-call burst has more than the 1-call run: faults by (object, symbol), by 2 MiB region, and the memory system calls (brk/mmap/munmap/mprotect/madvise)."""
import collections, os, re, subprocess, sys
label, perf = sys.argv[1], sys.argv[2]; cmd = sys.argv[4:]
def env(n): return dict(os.environ, BENCH_BUFFER_REPEAT=str(n), WGT_BACKEND='vulkan')
def faults(n):
    out = f'/tmp/pf_{label}_{n}.data'
    subprocess.run([perf, 'record', '-e', 'page-faults', '-c', '1', '-d', '-o', out, '--'] + cmd, env=env(n), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t = subprocess.run([perf, 'script', '-i', out, '-F', 'addr,ip,sym,dso'], capture_output=True, text=True).stdout
    sym, reg = collections.Counter(), collections.Counter()
    for l in t.splitlines():
        m = re.match(r'\s*([0-9a-f]+)\s+([0-9a-f]+)\s+(.*?)\s+\((.*)\)\s*$', l)
        if not m: continue
        a = int(m.group(1), 16); s = m.group(3); d = os.path.basename(m.group(4))
        sym[(d, s if not s.startswith('[unknown]') else 'ip=0x%x' % (int(m.group(2), 16) & 0xfff))] += 1
        reg[a >> 21] += 1
    return sym, reg
def sysc(n):
    out = f'/tmp/st_{label}_{n}.txt'
    subprocess.run(['strace', '-f', '-e', 'trace=brk,mmap,munmap,mprotect,madvise,mremap', '-o', out] + cmd, env=env(n), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    c = collections.Counter(); big = []
    for l in open(out):
        m = re.match(r'\d+\s+(\w+)\((.*)\)\s+=\s+(\S+)', l)
        if not m: continue
        name, args = m.group(1), m.group(2); c[name] += 1
    return c, open(out).read().splitlines()
s1, r1 = faults(1); s4, r4 = faults(4000)
print(f'## {label}: faults N=1 {sum(s1.values())}  N=4000 {sum(s4.values())}')
d = collections.Counter(); 
for k in set(s1) | set(s4): d[k] = s4[k] - s1[k]
print('-- more faults in the burst, by (object, symbol):')
for k, v in d.most_common(10): print(f'   {v:+6d}  {k[0]:34s} {k[1][:70]}')
dr = collections.Counter()
for k in set(r1) | set(r4): dr[k] = r4[k] - r1[k]
print('-- by 2 MiB region (address>>21), burst minus start-up only; regions with >=40 more faults:')
for k, v in dr.most_common(8):
    if v >= 40: print(f'   {v:+6d}  region 0x{k<<21:x}')
c1, l1 = sysc(1); c4, l4 = sysc(4000)
print('-- memory system calls, N=1 vs N=4000:', {k: (c1[k], c4[k]) for k in sorted(set(c1) | set(c4))})
tail = [l for l in l4 if re.search(r'\b(brk|mprotect|madvise|munmap|mremap)\(', l)][-14:]
print('-- last memory calls of the N=4000 run (the burst is at the end):'); [print('   ' + t[:150]) for t in tail]
