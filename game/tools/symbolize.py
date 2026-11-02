#!/usr/bin/env python3
"""usage: symbolize.py <nm -n output> <log file>
Finds the 'cosmoaddr2line <exe> <hex addresses...>' line a Cosmopolitan crash report prints and names each address from a sorted `nm -n -C` listing of the same build."""
import sys, re, bisect
syms = []
for line in open(sys.argv[1], errors='replace'):
    p = line.rstrip('\n').split(' ', 2)
    if len(p) == 3 and re.fullmatch(r'[0-9a-fA-F]+', p[0]) and p[1] in 'tTwWiI':
        syms.append((int(p[0], 16), p[2]))
syms.sort()
keys = [s[0] for s in syms]
for line in open(sys.argv[2], errors='replace'):
    m = re.search(r'cosmoaddr2line \S+ ((?:[0-9a-f]+ ?)+)', line)
    if m:
        for a in m.group(1).split():
            v = int(a, 16); i = bisect.bisect_right(keys, v) - 1
            print('  %s -> %s' % (a, ('%s+0x%x' % (syms[i][1][:160], v - syms[i][0])) if i >= 0 else '?'))
