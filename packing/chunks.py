#!/usr/bin/env python3
"""What a depot-style updater (fixed or content-defined chunks, each chunk compressed on its own) gets from two real builds, and what chunking costs in compression.
usage: chunks.py <old-file> <new-file>"""
import sys, hashlib, subprocess, random, os
old = open(sys.argv[1], 'rb').read(); new = open(sys.argv[2], 'rb').read()
print(f'old {len(old):,} bytes, new {len(new):,} bytes')
def fixed(d, n): return [d[i:i + n] for i in range(0, len(d), n)]
random.seed(1); GEAR = [random.getrandbits(64) for _ in range(256)]
def cdc(d, avg=1 << 16):
    mn, mx = avg // 4, avg * 4; mask = avg - 1; out = []; i = 0; n = len(d)
    while i < n:
        h = 0; j = i + mn; end = min(n, i + mx)
        if j >= end: out.append(d[i:end]); i = end; continue
        while j < end:
            h = ((h << 1) + GEAR[d[j]]) & 0xFFFFFFFFFFFFFFFF
            if not (h >> 40) & mask: j += 1; break
            j += 1
        out.append(d[i:j]); i = j
    return out
for name, f in (('fixed 1 MiB', lambda d: fixed(d, 1 << 20)), ('fixed 64 KiB', lambda d: fixed(d, 1 << 16)), ('content-defined ~64 KiB', cdc), ('content-defined ~16 KiB', lambda d: cdc(d, 1 << 14))):
    a = {hashlib.sha1(c).digest() for c in f(old)}; nb = f(new)
    reuse = sum(len(c) for c in nb if hashlib.sha1(c).digest() in a)
    print(f'{name:26s} chunks in new: {len(nb):5d}; bytes already present in the old build: {reuse:>12,} ({100 * reuse / len(new):.1f}%); to download: {len(new) - reuse:,}')
def comp(cmd, d): return len(subprocess.run(cmd, input=d, capture_output=True).stdout)
for label, cmd in (('zstd -19', ['zstd', '-19', '-c', '-q']), ('xz -6', ['xz', '-6', '-c'])):
    whole = comp(cmd, new)
    for cs in (1 << 20, 1 << 18):
        per = sum(comp(cmd, c) for c in fixed(new, cs))
        print(f'{label}: whole file {whole:,}; each {cs >> 10} KiB chunk compressed alone {per:,} ({100 * (per - whole) / whole:+.1f}%)')
