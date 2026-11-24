#!/usr/bin/env python3
# analyze.py FPS N < log("time index" per shown frame): loop-point timing.
import sys, statistics
fps, N = float(sys.argv[1]), int(sys.argv[2]); T = 1 / fps
rows = [tuple(map(float, l.split())) for l in sys.stdin if l.strip()]
rows = [(t, int(i)) for t, i in rows][int(fps):]       # skip the first second (startup)
dup = skip = 0; loopgaps = []; gaps = []
for (t0, a), (t1, b) in zip(rows, rows[1:]):
    d = t1 - t0
    if b == a: dup += 1
    elif b != (a + 1) % N: skip += 1
    (loopgaps if (a == N - 1 and b == 0) else gaps).append(d)
loops = len(loopgaps)
print(f"frames {len(rows)} loops {loops} dup {dup} skip {skip} | "
      f"interval median {statistics.median(gaps)*1e3:.2f} ms max {max(gaps)*1e3:.2f} | "
      f"loop-point max {max(loopgaps)*1e3 if loopgaps else 0:.2f} ms mean {statistics.mean(loopgaps)*1e3 if loopgaps else 0:.2f} | "
      f"gaps>1.5T {sum(d > 1.5*T for d in gaps+loopgaps)}")
