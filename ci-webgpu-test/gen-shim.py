#!/usr/bin/env python3
"""Generate dl_shim.h: function-pointer table for every wgpu* call in wgt.c, resolved with cosmo_dlsym + cosmo_dltramp."""
import re, sys
src = open(sys.argv[1] if len(sys.argv) > 1 else 'wgt.c').read()
src = src.split('#ifdef DLSHIM', 1)[0] + src.split('#endif', 1)[-1]  # ignore the shim hook itself
fns = sorted(set(re.findall(r'\b(wgpu[A-Z]\w+)\(', src)))
h = '#include <dlfcn.h>\n#define MSABI __attribute__((ms_abi))\n'
# per function: p_ = System V pointer (through cosmo_dltramp, Linux/macOS), m_ = Microsoft-ABI pointer (Windows DLL, struct-by-value handled by the compiler)
for f in fns:
    h += f'typedef __typeof__({f}) MSABI m_{f}_t;\nstatic __typeof__(&{f}) p_{f}; static m_{f}_t *m_{f};\n'
h += 'static int dl_load(void *h) {\n'
for f in fns:
    h += f'  m_{f} = (m_{f}_t *)cosmo_dlsym(h, "{f}"); if (!m_{f}) {{ puts("missing {f}"); return 9; }}\n'
    h += f'  p_{f} = IsWindows() ? 0 : (__typeof__(&{f}))cosmo_dltramp((void *)m_{f});\n'
h += '  return 0;\n}\n'
for f in fns:
    h += f'#define {f}(...) (IsWindows() ? m_{f}(__VA_ARGS__) : p_{f}(__VA_ARGS__))\n'
open('dl_shim.h', 'w').write(h)
print(len(fns), 'functions')
