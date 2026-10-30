#!/usr/bin/env python3
"""Compresses the given files with every codec under test (real command line tools), prints the size/ratio/time table, and writes the subset used for the decode-speed benchmark
plus its manifest.   usage: prep_data.py <outdir> <label=path> ...   (a label ending in -x86 or -arm gets the matching xz BCJ variant)"""
import sys, os, subprocess, time, zlib, shutil
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
files = [a.split('=', 1) for a in sys.argv[2:]]
CODECS = [  # name, command, in bench?
 ('gzip-6',  ['gzip', '-6', '-c'], False), ('gzip-9',  ['gzip', '-9', '-c'], True),
 ('zstd-1',  ['zstd', '-1', '-c', '-q'], True), ('zstd-3', ['zstd', '-3', '-c', '-q'], True), ('zstd-9', ['zstd', '-9', '-c', '-q'], True), ('zstd-19', ['zstd', '-19', '-c', '-q'], True),
 ('zstd-22', ['zstd', '--ultra', '-22', '--long=27', '-c', '-q'], False),
 ('lz4-1',   ['lz4', '-1', '-c', '-q'], True), ('lz4-12', ['lz4', '-12', '-c', '-q'], True),
 ('xz-6',    ['xz', '-6', '-c'], True), ('xz-9e', ['xz', '-9e', '-c'], False),
 ('brotli-9', ['brotli', '-q', '9', '-c'], False), ('brotli-11', ['brotli', '-q', '11', '-w', '24', '-c'], False),
]
BIG_ONLY = {'zstd-22', 'xz-9e', 'brotli-11'}
manifest = []
print('| file | codec | size | ratio | compress s |')
print('|---|---|---:|---:|---:|')
for label, path in files:
    data = open(path, 'rb').read(); n = len(data); crc = zlib.crc32(data)
    print(f'| {label} | none | {n:,} | 1.000 | |')
    cods = list(CODECS)
    if label.endswith('-x86'): cods.append(('xz-6-bcj', ['xz', '-6', '--x86', '--lzma2=preset=6', '-c'], True))
    if label.endswith('-arm'): cods.append(('xz-6-bcj', ['xz', '-6', '--arm64', '--lzma2=preset=6', '-c'], True))
    for name, cmd, inbench in cods:
        if shutil.which(cmd[0]) is None: print(f'| {label} | {name} | (tool missing) | | |'); continue
        t = time.time()
        r = subprocess.run(cmd, input=data, capture_output=True)
        dt = time.time() - t
        if r.returncode: print(f'| {label} | {name} | failed rc={r.returncode} | | |'); continue
        c = r.stdout
        print(f'| {label} | {name} | {len(c):,} | {len(c) / n:.3f} | {dt:.1f} |', flush=True)
        if inbench:
            fn = f'{label}.{name}'; open(os.path.join(out, fn), 'wb').write(c)
            manifest.append(f'{name.split("-bcj")[0]} {out}/{fn} {n} {crc:08x} {label}.{name}')
open(os.path.join(out, 'manifest.txt'), 'w').write('\n'.join(manifest) + '\n')
