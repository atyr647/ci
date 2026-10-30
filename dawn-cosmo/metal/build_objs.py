#!/usr/bin/env python3
"""Run on macOS. Compiles Dawn's Metal backend (Objective-C++, patched by patch_metal.py) plus MetalCosmo.mm with the Cosmopolitan toolchain's clang, against the
Apple SDK headers, using the flags exported by export_inputs.py from the Cosmopolitan arm64 build of Dawn. Keeps the arm64 halves of the fat objects, lists the
symbols the objects need from outside, and generates the Objective-C runtime shim (gen_objc_shim.py).
usage: build_objs.py <inputs-dir> <cosmocc-bin-dir> <sdk-path> <out-dir>"""
import glob, json, os, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
inputs, bindir, sdk, out = [os.path.abspath(a) for a in sys.argv[1:5]]
here = os.path.dirname(os.path.abspath(__file__))
os.makedirs(out, exist_ok=True)
flags = [f.replace('@ROOT@', inputs) for f in json.load(open(os.path.join(inputs, 'flags.json')))]
compat = os.path.join(out, 'cosmo_apple_compat.h')
r = subprocess.run([sys.executable, os.path.join(here, '../../backend-spikes/metal-shims/gen_compat.py'), sdk, compat], capture_output=True, text=True); print(r.stdout[-300:], r.stderr[-500:])
r = subprocess.run([sys.executable, os.path.join(here, '../patch_metal.py'), os.path.join(inputs, 'dawn')], capture_output=True, text=True); print(r.stdout, r.stderr[-500:])
assert r.returncode == 0
shutil.copy(os.path.join(here, 'MetalCosmo.mm'), os.path.join(inputs, 'dawn/src/dawn/native/metal/MetalCosmo.mm'))
srcs = sorted(glob.glob(os.path.join(inputs, 'dawn/src/dawn/native/metal/*.mm')))
print(len(srcs), 'translation units')
cxx = os.path.join(bindir, 'cosmoc++')
objdir = os.path.join(out, 'fat'); os.makedirs(objdir, exist_ok=True)
base = [cxx, '-mclang', '-c', '-x', 'objective-c++', '-include', compat, '-fblocks', '-fobjc-runtime=macosx', '-fno-objc-arc', '-Wno-everything',
        '-DDAWN_COSMO_AS_APPLE=1', '-DOBJC_OLD_DISPATCH_PROTOTYPES=1', '-F' + sdk + '/System/Library/Frameworks', '-idirafter' + sdk + '/usr/include']
def one(f):
    o = os.path.join(objdir, os.path.basename(f) + '.o')
    p = subprocess.run(base + flags + [f, '-o', o], capture_output=True, text=True)
    return f, p
bad = 0
with ThreadPoolExecutor(3) as ex:
    for f, p in ex.map(one, srcs):
        errs = [l for l in p.stderr.splitlines() if ' error' in l or 'fatal error' in l]
        print(('OK   ' if p.returncode == 0 else 'FAIL ') + os.path.basename(f), flush=True)
        if p.returncode != 0:
            bad += 1; print('\n'.join(p.stderr.splitlines()[:25]))
if bad: sys.exit(f'{bad} translation units failed')
# the arm64 slices
for f in sorted(glob.glob(os.path.join(objdir, '.aarch64', '*.o')) + glob.glob(os.path.join(objdir, '*.o'))):
    pass
objs = sorted(glob.glob(os.path.join(objdir, '.aarch64', '*.o')))
assert len(objs) == len(srcs), (len(objs), len(srcs), os.listdir(objdir))
dest = os.path.join(out, 'objs'); os.makedirs(dest, exist_ok=True)
for o in objs: shutil.copy(o, os.path.join(dest, os.path.basename(o)))
nm = os.path.join(bindir, 'aarch64-linux-cosmo-nm')
und = set()
for o in objs:
    for l in subprocess.run(['sh', nm, '-u', o], capture_output=True, text=True).stdout.splitlines():
        parts = l.split()
        if parts: und.add(parts[-1])
defined = set()
for o in objs:
    for l in subprocess.run(['sh', nm, '--defined-only', o], capture_output=True, text=True).stdout.splitlines():
        parts = l.split()
        if parts: defined.add(parts[-1])
# what Cosmopolitan's own C and C++ libraries provide is NOT routed to the Apple frameworks
libdir = os.path.join(os.path.dirname(bindir.rstrip('/')), 'aarch64-linux-cosmo', 'lib')
provided = set()
for lib in ('libcosmo.a', 'libcxx.a'):
    for l in subprocess.run(['sh', nm, '--defined-only', '-g', os.path.join(libdir, lib)], capture_output=True, text=True).stdout.splitlines():
        parts = l.split()
        if len(parts) == 3: provided.add(parts[2])
print(len(provided), 'symbols provided by Cosmopolitan libc/libc++')
und = sorted(s for s in und if s not in defined and s not in provided and not s.startswith('dawn_cosmo_'))
open(os.path.join(out, 'undefined.txt'), 'w').write('\n'.join(und) + '\n')
print(len(und), 'undefined symbols:'); print('\n'.join('  ' + s for s in und if not s.startswith(('_Z', '__cxa', '__gxx', '_Unwind'))))
r = subprocess.run([sys.executable, os.path.join(here, 'gen_objc_shim.py'), os.path.join(out, 'undefined.txt'), out], capture_output=True, text=True); print(r.stdout, r.stderr[-800:])
assert r.returncode == 0
