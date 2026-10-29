#!/usr/bin/env python3
"""Generate wt_shim.h: for every wasmtime_/wasm_/wasi_ function the host calls, a System V pointer (cosmo_dltramp) and a Microsoft-ABI pointer.
Calls are dispatched at run time (IsWindows()). Same technique as ci-webgpu-test/gen-shim.py."""
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'#include "wt_shim.h"', '', src)
fns = sorted(set(re.findall(r'\b((?:wasmtime|wasm|wasi)_[a-z0-9_]+)\(', src)))
# only names that are real library functions (declared in the headers), not types/macros/our own statics
hdr = open(sys.argv[2]).read() if len(sys.argv) > 2 else ''
fns = [f for f in fns if f not in ('wasm_valtype_new_i32',) and (not hdr or f.startswith('wasmtime_config_') or re.search(r'\b' + f + r'\s*\(', hdr))]   # wasmtime_config_*_set are declared through the WASMTIME_CONFIG_PROP macro, so their names are not literal in the header text
h = '#define MSABI __attribute__((ms_abi))\n'
for f in fns:
    h += f'typedef __typeof__({f}) MSABI m_{f}_t;\nstatic __typeof__(&{f}) p_{f}; static m_{f}_t *m_{f};\n'
h += 'static int wt_load(void *h) {\n'
for f in fns:
    h += f'  m_{f} = (m_{f}_t *)cosmo_dlsym(h, "{f}"); if (!m_{f}) {{ puts("missing {f}"); return 9; }}\n'
    h += f'  p_{f} = IsWindows() ? 0 : (__typeof__(&{f}))cosmo_dltramp((void *)m_{f});\n'
h += '  return 0;\n}\n'
h += '#define WT_CB(f, T) (IsWindows() ? (T)(void *)f##_ms : (T)(void *)(f))\n'
for f in fns:
    h += f'#define {f}(...) (IsWindows() ? m_{f}(__VA_ARGS__) : p_{f}(__VA_ARGS__))\n'
open('wt_shim.h', 'w').write(h)
print(len(fns), 'functions')
