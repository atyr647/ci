# usage: futexmap.py <hex address> <maps file (range + name per line)>  - which mapping holds an address
import sys
a = int(sys.argv[1], 16)
for l in open(sys.argv[2]):
    r, n = (l.split() + [''])[:2]; lo, hi = [int(x, 16) for x in r.split('-')]
    if lo <= a < hi:
        print('futex word', hex(a), 'lies in', r, n or '(anonymous)'); break
