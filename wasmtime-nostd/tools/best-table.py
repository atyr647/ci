#!/usr/bin/env python3
"""Reads lines 'KERNEL <config>-<name> <ms> <checksum>' on stdin and prints a table: rows = kernel, columns = config (fastest value)."""
import re, sys, collections
b = collections.defaultdict(lambda: 1e30)
for l in sys.stdin:
    m = re.match(r'KERNEL (\S+) (\S+) (\S+)', l)
    if m: b[(m.group(1), m.group(2))] = min(b[(m.group(1), m.group(2))], float(m.group(3)))
ks = sorted({k for _, k in b}); cs = sorted({c for c, _ in b})
print('| kernel | ' + ' | '.join(cs) + ' |'); print('|---' * (len(cs) + 1) + '|')
for k in ks: print('| ' + k + ' | ' + ' | '.join('%.2f' % b[(c, k)] if (c, k) in b else '-' for c in cs) + ' |')
