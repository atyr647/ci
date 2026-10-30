#!/usr/bin/env python3
"""Compiles the shootout wasm variants with every ahead-of-time route that is installed, smoke-tests each result and writes the runner.py spec.
env: WASMTIME (required), WASMER, WASMEDGE, WAMRC, IWASM, NODE, W2C (wasm2c binary), WABT (wabt source dir: wasm2c runtime + simde), CCS (comma list: gcc,clang), MARCH
usage: aot_matrix.py WASMDIR WORKDIR SPEC.json"""
import os, subprocess, sys, json, platform, concurrent.futures as cf
D, WD, OUT = sys.argv[1:4]
E = os.environ; os.makedirs(WD, exist_ok=True)
rows, log = [], []
def sh(cmd, timeout=900):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr)
def note(s): print(s, flush=True); log.append(s)
def smoke(name, cmd):
    rc, out = sh(cmd + ' zzz', 300)
    if rc == 0: rows.append({'name': name, 'cmd': cmd}); return True
    note(f'SMOKE FAIL {name}: rc={rc} {out.strip().splitlines()[-1][:150] if out.strip() else ""}'); return False
W = E['WASMTIME']
for v in ('scalar', 'autovec', 'simd', 'simd-u2', 'simd-vb32', 'relaxed', 'relaxed-u2'):
    smoke(f'wasmtime {v}', f'"{W}" run {D}/so-{v}.wasm')
VARS = ('scalar', 'simd', 'simd-u2', 'simd-vb32')
# ---- wasmer: three compiler backends
if E.get('WASMER'):
    rc, out = sh(f'"{E["WASMER"]}" --version; "{E["WASMER"]}" compile --help | grep -i -E "llvm|cranelift|singlepass|simd|cpu|target|enable" | head -14'); note('wasmer: ' + out.strip().replace('\n', ' | ')[:600])
    for be in ('llvm', 'cranelift', 'singlepass'):
        for v in VARS:
            art = f'{WD}/wasmer-{be}-{v}.wasmu'
            rc, out = sh(f'"{E["WASMER"]}" compile --{be} -o {art} {D}/so-{v}.wasm')
            if rc != 0: note(f'wasmer compile --{be} {v}: rc={rc} {out.strip()[-200:]}'); continue
            smoke(f'wasmer-{be} {v}', f'"{E["WASMER"]}" run --{be} {art}')
# ---- WAMR AOT
if E.get('WAMRC') and E.get('IWASM'):
    rc, out = sh(f'"{E["WAMRC"]}" --help 2>&1 | grep -i -E "cpu|target|simd|opt-level|bounds" | head -12'); note('wamrc: ' + out.strip().replace('\n', ' | ')[:700])
    isa = '--target=x86_64 --cpu-features=+avx2,+fma,+bmi2' if platform.machine() == 'x86_64' else ''
    for tag, extra in (('default', ''), ('avx2', isa)):
        if tag == 'avx2' and not isa: continue
        for v in VARS:
            art = f'{WD}/wamr-{tag}-{v}.aot'
            rc, out = sh(f'"{E["WAMRC"]}" {extra} -o {art} {D}/so-{v}.wasm')
            if rc != 0: note(f'wamrc {tag} {v}: rc={rc} {out.strip()[-200:]}'); continue
            smoke(f'wamr-aot-{tag} {v}', f'"{E["IWASM"]}" {art}')
# ---- WasmEdge AOT (LLVM)
if E.get('WASMEDGE'):
    rc, out = sh(f'"{E["WASMEDGE"]}" compile --help 2>&1 | head -30'); note('wasmedge compile: ' + out.strip().replace('\n', ' | ')[:700])
    for tag, extra in (('O3', '--optimize 3'),):
        for v in VARS:
            art = f'{WD}/wedge-{tag}-{v}.so'
            rc, out = sh(f'"{E["WASMEDGE"]}" compile {extra} {D}/so-{v}.wasm {art}')
            if rc != 0: note(f'wasmedge compile {tag} {v}: rc={rc} {out.strip()[-200:]}'); continue
            smoke(f'wasmedge-aot-{tag} {v}', f'"{E["WASMEDGE"]}" {art}')
# ---- Node / V8 (x64): TurboFan with and without the experimental 128->256 bit revectoriser
if E.get('NODE'):
    js = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'node_run.js')
    for tag, fl in (('liftoff-default', ''), ('turbofan', '--no-liftoff'), ('turbofan+revec', '--no-liftoff --experimental-wasm-revectorize')):
        for v in ('scalar', 'simd', 'simd-u2', 'simd-vb32'):
            smoke(f'node-{tag} {v}', f'"{E["NODE"]}" {fl} {js} {D}/so-{v}.wasm')
# ---- wasm2c (wabt master) -> C -> gcc / clang
if E.get('W2C'):
    RT = f'{E["WABT"]}/wasm2c'; SIMDE = f'{E["WABT"]}/third_party/simde'; M = E.get('MARCH', '-march=native')
    jobs = []
    for v in ('scalar', 'autovec', 'simd', 'simd-u2', 'simd-vb32', 'relaxed', 'relaxed-u2'):
        d = f'{WD}/w2c-{v}'; os.makedirs(d, exist_ok=True)
        rc, out = sh(f'"{E["W2C"]}" {"--enable-relaxed-simd " if "relaxed" in v else ""}{D}/so-{v}.wasm -n so -o {d}/so.c')
        if rc != 0: note(f'wasm2c {v}: rc={rc} {out.strip()[-300:]}'); continue
        note(f'wasm2c {v}: ok, {os.path.getsize(d + "/so.c")} bytes of C')
        for cc in E.get('CCS', 'gcc,clang').split(','):
            for isa, flags in (('base', ''), ('host', M), ('host+oobelim', M + ' -ffp-contract=fast -DWASM_RT_NONCONFORMING_ALLOW_OOB_READ_ELIMINATION=1')):
                if isa != 'host+oobelim' and v != 'simd': continue
                jobs.append((v, cc, isa, flags, d))
    def build(j):
        v, cc, isa, flags, d = j; exe = f'{WD}/w2c-{v}-{cc}-{isa}'
        cmd = (f'{cc} -O3 {flags} -DWASM_RT_TRAP_HANDLER=w2c_trap_handler -DW2C_NAME=so -DW2C_HEADER=\\"so.h\\" -I{RT} -I{d} -I{SIMDE} -Wno-everything '
               f'{os.path.dirname(os.path.abspath(__file__))}/w2c_main.c {d}/so.c {RT}/wasm-rt-impl.c {RT}/wasm-rt-mem-impl.c -o {exe} -lm')
        rc, out = sh(cmd, 1500); return j, exe, rc, out
    with cf.ThreadPoolExecutor(4) as ex:
        for j, exe, rc, out in ex.map(build, jobs):
            v, cc, isa, _, _ = j; name = f'wasm2c {v} {cc} {isa}'
            if rc != 0: note(f'BUILD FAIL {name}: {out.strip()[-300:]}'); continue
            smoke(name, exe)
json.dump(rows, open(OUT, 'w'), indent=1); note(f'{len(rows)} runnable rows')
open(f'{WD}/notes.txt', 'w').write('\n'.join(log))
