#!/usr/bin/env python3
"""Spike: how far do Dawn's D3D12 backend sources get when compiled with the Cosmopolitan GCC against Wine's Windows/DXGI/D3D11 headers (LP64-safe, COM methods
automatically ms_abi) and Microsoft's DirectX-Headers (newer d3d12*.h)? Compile only. The rest of Dawn is compiled as "Linux"; these TUs pretend to be Windows
AFTER the C++ library headers have been parsed (stubs/pre.h), so libc++ keeps its POSIX code paths.
usage: d3d12_spike.py <flag-template-command-file> <dawn-src> <build-dir> <wine-include-root> <stubs-dir> [limit]"""
import re, shlex, subprocess, sys, os, glob, collections
from concurrent.futures import ThreadPoolExecutor
tmpl, dawn, build, wine, stubs = sys.argv[1:6]
limit = int(sys.argv[6]) if len(sys.argv) > 6 else 10**9
toks = shlex.split(open(tmpl).read().strip())
base = []; skip = 0
for t in toks:
    if skip: skip -= 1; continue
    if t in ('-o', '-MT', '-MF'): skip = 1; continue
    if t in ('-c', '-MD'): continue
    if re.search(r'\.(cpp|cc|c)$', t): continue
    base.append(t)
extra = ['-DDAWN_ENABLE_BACKEND_D3D12', '-DDAWN_ENABLE_BACKEND_D3D11', '-DDAWN_COSMO_AS_WINDOWS=1', '-DNOMINMAX', '-DWIN32_LEAN_AND_MEAN', '-fpermissive', '-w', '-fsyntax-only',
         '-include', os.path.join(stubs, 'pre.h'), '-I' + stubs,
         '-I' + os.path.join(dawn, 'third_party/directx-headers/src/include/directx'), '-I' + os.path.join(dawn, 'third_party/directx-headers/src/include'),
         '-I' + os.path.join(dawn, 'third_party/directx-shader-compiler/src/include/dxc'),
         '-I' + os.path.join(wine, 'windows'), '-I' + wine]
files = sorted(glob.glob(os.path.join(dawn, 'src/dawn/native/d3d12/*.cpp')) + glob.glob(os.path.join(dawn, 'src/dawn/native/d3d/*.cpp')))[:limit]
print(f'{len(files)} translation units (d3d + d3d12)', flush=True)
def one(f):
    p = subprocess.run(base + extra + ['-c', f], cwd=build, capture_output=True, text=True)
    errs = [l for l in p.stderr.splitlines() if ' error' in l or 'fatal error' in l]
    return f, errs
cnt = collections.Counter(); ok = 0
with ThreadPoolExecutor(4) as ex:
    for f, errs in ex.map(one, files):
        if not errs: ok += 1
        for l in errs:
            m = re.sub(r'^.*?(error:|fatal error:)', r'\1', l); m = re.sub(r"'[^']*'", "'_'", m)[:170]; cnt[m] += 1
        print(f"{'OK  ' if not errs else 'FAIL'} {os.path.basename(f):44s} errors={len(errs)}", flush=True)
print(f'\n{ok}/{len(files)} files compile clean\nmost common distinct errors:')
for m, c in cnt.most_common(30): print(f'  {c:5d}  {m}')
