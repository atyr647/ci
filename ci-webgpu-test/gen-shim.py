#!/usr/bin/env python3
"""Generate dl_shim.h: function-pointer table for every wgpu* call in wgt.c, resolved with cosmo_dlsym + cosmo_dltramp."""
import re, sys
src = open(sys.argv[1] if len(sys.argv) > 1 else 'wgt.c').read()
src = src.split('#ifdef DLSHIM', 1)[0] + src.split('#endif', 1)[-1]  # ignore the shim hook itself
fns = sorted(set(re.findall(r'\b(wgpu[A-Z]\w+)\(', src)))
h = '#include <dlfcn.h>\n'
h += ''.join(f'static __typeof__(&{f}) p_{f};\n' for f in fns)
h += 'static int dl_load(void *h) {\n'
h += ''.join(f'  p_{f} = (__typeof__(&{f}))cosmo_dltramp(cosmo_dlsym(h, "{f}")); if (!p_{f}) {{ puts("missing {f}"); return 9; }}\n' for f in fns)
h += '  return 0;\n}\n'
h += ''.join(f'#define {f} p_{f}\n' for f in fns)
open('dl_shim.h', 'w').write(h)
print(len(fns), 'functions')
