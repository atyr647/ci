#!/usr/bin/env python3
"""Builds the Wasmtime configuration matrix (JSON spec for runner.py) and probes which spelling of the Cranelift ISA flags the v50 CLI accepts.
usage: wt_matrix.py WASMTIME WASMDIR OUT.json   (WASMDIR holds so-*.wasm)"""
import json, platform, subprocess, sys, os

W, D, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
arch = platform.machine().lower()
x64 = arch in ('x86_64', 'amd64')
def ok(flags, wasm='so-simd.wasm'):
    r = subprocess.run(f'"{W}" run {flags} {D}/{wasm} zzz', shell=True, capture_output=True, text=True, timeout=120)
    return r.returncode == 0, (r.stderr.strip().splitlines() or [''])[-1][:160]

def spelling(key, val='false'):
    for sp in (f'cranelift-{key}', f'cranelift-{key.replace("_", "-")}', f'cranelift_{key}'):
        good, msg = ok(f'-C {sp}={val}')
        print(f'probe -C {sp}={val}: {"ok" if good else "REJECTED " + msg}')
        if good: return sp
    return None

rows = []
def add(name, flags, wasm='so-simd.wasm'): rows.append({'name': name, 'cmd': f'"{W}" run {flags} {D}/{wasm}'})
S = 'so-simd.wasm'
add('default (host CPU features)', '')
if x64:
    sp = {k: spelling(k) for k in ('has_avx', 'has_avx2', 'has_fma', 'has_bmi1', 'has_bmi2', 'has_lzcnt', 'has_popcnt', 'has_sse41', 'has_sse42', 'has_ssse3')}
    def off(*keys): return ' '.join(f'-C {sp[k]}=false' for k in keys if sp.get(k))
    add('no AVX2/FMA (AVX only)', off('has_avx2', 'has_fma'))
    add('no AVX/AVX2/FMA (SSE4.2)', off('has_avx', 'has_avx2', 'has_fma'))
    add('no FMA only', off('has_fma'))
    add('no BMI1/BMI2/LZCNT/POPCNT', off('has_bmi1', 'has_bmi2', 'has_lzcnt', 'has_popcnt'))
    add('SSE4.2 only + no bmi/lzcnt/popcnt', off('has_avx', 'has_avx2', 'has_fma', 'has_bmi1', 'has_bmi2', 'has_lzcnt', 'has_popcnt'))
    add('no SSE4.1/4.2 and no AVX (SSSE3 only)', off('has_avx', 'has_avx2', 'has_fma', 'has_sse41', 'has_sse42'))
for o in ('0', '1', '2', 's'): add(f'opt-level={o}', f'-O opt-level={o}')
add('regalloc single-pass', '-O regalloc-algorithm=single-pass')
add('explicit bounds checks (signals-based-traps=n)', '-O signals-based-traps=n')
add('dynamic memory (reservation 0, guard 0)', '-O memory-reservation=0 -O memory-guard-size=0')
add('memory-may-move=y', '-O memory-may-move=y')
add('memory-reservation=4GiB, guard=0', '-O memory-reservation=4294967296 -O memory-guard-size=0')
add('fuel=1e15', '-W fuel=1000000000000000')
add('nan-canonicalization=y', '-W nan-canonicalization=y')
add('inlining=y', '-C inlining=y')
add('winch (baseline compiler)', '-C compiler=winch')
# precompiled .cwasm for an explicit target (what an ahead-of-time build for a fixed CPU class would use)
trip = {'x86_64': 'x86_64-unknown-linux-gnu', 'aarch64': 'aarch64-unknown-linux-gnu', 'arm64': 'aarch64-apple-darwin', 'amd64': 'x86_64-pc-windows-msvc'}.get(arch, '')
sysname = platform.system()
if sysname == 'Darwin': trip = 'aarch64-apple-darwin' if not x64 else 'x86_64-apple-darwin'
if sysname == 'Windows' or sysname.startswith(('MINGW', 'MSYS', 'CYGWIN')): trip = 'x86_64-pc-windows-msvc'
os.makedirs('cwasm', exist_ok=True)
def cw(name, cflags, rflags=''):
    out = f'cwasm/{name.split()[0]}.cwasm'
    r = subprocess.run(f'"{W}" compile --target {trip} {cflags} -o {out} {D}/{S}', shell=True, capture_output=True, text=True)
    print(f'compile {name}: rc={r.returncode} {(r.stderr.strip().splitlines() or [""])[-1][:140]}')
    if r.returncode == 0: rows.append({'name': name, 'cmd': f'"{W}" run --allow-precompiled {rflags} {out}'})
if trip:
    cw('cwasm-baseline (--target only, no extra flags)', '')
    out = 'cwasm/hostdefault.cwasm'
    r = subprocess.run(f'"{W}" compile -o {out} {D}/{S}', shell=True, capture_output=True, text=True)
    if r.returncode == 0: rows.append({'name': 'cwasm-host-default (compile without --target)', 'cmd': f'"{W}" run --allow-precompiled {out}'})
    if x64:
        for pre in ('x86-64-v3', 'x86_64_v3', 'haswell'):
            r = subprocess.run(f'"{W}" compile --target {trip} -C cranelift-{pre} -o /dev/null {D}/{S}', shell=True, capture_output=True, text=True)
            print(f'probe preset -C cranelift-{pre}: rc={r.returncode} {(r.stderr.strip().splitlines() or [""])[-1][:100]}')
            if r.returncode == 0:
                cw(f'cwasm-{pre} (preset)', f'-C cranelift-{pre}'); break
        feats = ' '.join(f'-C {sp[k]}=true' for k in ('has_sse41', 'has_sse42', 'has_avx', 'has_avx2', 'has_fma', 'has_bmi1', 'has_bmi2', 'has_lzcnt', 'has_popcnt') if sp.get(k))
        cw('cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt)', feats)
json.dump(rows, open(OUT, 'w'), indent=1)
print(f'{len(rows)} configurations')
