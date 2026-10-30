#!/usr/bin/env python3
"""Spike: how far do Dawn's Metal backend sources get when compiled with the Cosmopolitan toolchain's clang (cosmocc -mclang) as Objective-C++ against the Apple SDK headers?
usage: metal_spike.py <build-dir-with-compile_commands.json> <cosmocc> <sdk-path> [limit]
Prints, per file, OK or the number of errors, then the most common distinct errors. Compiles to a throw-away object; cosmocc builds the x86-64 and arm64 slices."""
import json, re, shlex, subprocess, sys, os, collections
build, cosmocc, sdk = sys.argv[1], sys.argv[2], sys.argv[3]
cosmocxx = os.path.join(os.path.dirname(cosmocc), 'cosmoc++')   # the C++ driver adds libc++ to the include path
compat = os.path.join('/tmp', 'cosmo_apple_compat.h')
print(subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'metal-shims/gen_compat.py'), sdk, compat], capture_output=True, text=True).stdout)
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 10**9
cdb = json.load(open(os.path.join(build, 'compile_commands.json')))
metal = [e for e in cdb if re.search(r'/src/dawn/native/metal/[^/]+\.(mm|cpp)$', e['file'])]
print(f'{len(metal)} translation units in src/dawn/native/metal')
APPLE_DEFS = ['-DDAWN_COSMO_AS_APPLE=1', '-DOBJC_OLD_DISPATCH_PROTOTYPES=1']   # __APPLE__ & co. come from the compat header, AFTER the C/C++ library headers
OBJ = os.environ.get('METAL_OBJ_DIR', '/tmp/metal-objs'); os.makedirs(OBJ, exist_ok=True)
errors = collections.Counter(); examples = {}; results = []; first_dump = []
for e in metal[:limit]:
    toks = shlex.split(e['command'])
    keep = []; skip = 0
    for t in toks[1:]:
        if skip: skip -= 1; continue
        if t in ('-o', '-MF', '-MT', '-arch', '-isysroot', '-target', '--target'): skip = 1; continue
        if t in ('-c', '-MD', '-MMD') or t.startswith('-mmacosx-version-min') or t.startswith('-fcolor') or t.startswith('-Werror') or t.startswith('-Wno-') and False: continue
        if t == e['file'] or t.endswith(('.mm', '.cpp')) and t.startswith('/') and os.path.basename(t) == os.path.basename(e['file']): continue
        keep.append(t)
    cmd = [cosmocxx, '-mclang', '-c', '-x', 'objective-c++', '-include', compat, '-fblocks', '-fobjc-runtime=macosx', '-Wno-everything'] + APPLE_DEFS + \
          ['-F' + sdk + '/System/Library/Frameworks', '-idirafter' + sdk + '/usr/include'] + keep + [e['file'], '-o', os.path.join(OBJ, os.path.basename(e['file']) + '.o')]
    p = subprocess.run(cmd, capture_output=True, text=True)
    errs = [l for l in p.stderr.splitlines() if ' error:' in l or 'fatal error' in l]
    if errs and not first_dump: first_dump = [(os.path.basename(e['file']), l) for l in p.stderr.splitlines() if 'error' in l][:14]
    for l in errs:
        m = re.sub(r'^.*?(error:|fatal error:)', r'\1', l); m = re.sub(r"'[^']*'", "'_'", m)[:150]; errors[m] += 1; examples.setdefault(m, l)
    results.append((os.path.basename(e['file']), len(errs)))
    print(f"{'OK  ' if not errs else 'FAIL'} {os.path.basename(e['file']):42s} errors={len(errs)}", flush=True)
ok = sum(1 for _, n in results if n == 0)
print(f'\n{ok}/{len(results)} files compile clean')
print('most common distinct errors (message shape, count):')
for m, c in errors.most_common(25): print(f'  {c:5d}  {m}')
print('\nfirst raw example of each shape:')
for m, c in errors.most_common(25): print('  ' + examples[m][:300])

import subprocess as _sp
def _show(title, cmd):
    r = _sp.run(cmd, capture_output=True, text=True); print('\n--- ' + title); print((r.stdout + r.stderr)[:3500])
inc = os.path.join(sdk, 'usr/include')
if any('ConditionalMacros' in l for _, l in first_dump):
    _show('ConditionalMacros.h 120-195', ['sed', '-n', '120,195p', os.path.join(inc, 'ConditionalMacros.h')])
if any('i386/types.h' in l for _, l in first_dump):
    _show('i386/types.h 100-120', ['sed', '-n', '100,120p', os.path.join(inc, 'i386/types.h')])
if any('__nullable' in l for _, l in first_dump):
    _show('where __nullable is defined', ['grep', '-rn', '-m3', '#\\s*define\\s*__nullable', inc, os.path.join(sdk, 'System/Library/Frameworks/Foundation.framework/Headers')])
    _show('sys/cdefs.h nullability block', ['grep', '-n', '-B3', '-A3', '__nullable', os.path.join(inc, 'sys/cdefs.h')])
if any('TargetConditionals' in l for _, l in first_dump):
    print('\nTargetConditionals.h around the #error:'); print(_sp.run(['sed','-n','330,395p',os.path.join(sdk,'usr/include/TargetConditionals.h')],capture_output=True,text=True).stdout)
print('\nfirst errors, in order, of the first failing file (later ones are usually cascades):')
for n, l in first_dump: print('  ' + n + ': ' + l.replace(sdk, '$SDK')[:260])

# ---- what the objects need from the outside (the list the in-file Objective-C runtime shim has to provide) ----
import glob as _glob
nm = os.path.join(os.path.dirname(cosmocc), 'x86_64-linux-cosmo-nm'); readelf = os.path.join(os.path.dirname(cosmocc), 'x86_64-linux-cosmo-readelf')
objs = sorted(_glob.glob(os.path.join(OBJ, '*.o')))
und = collections.Counter(); secs = collections.Counter()
for o in objs:
    for l in subprocess.run([nm, '-u', o], capture_output=True, text=True).stdout.splitlines():
        sym = l.split()[-1] if l.split() else ''
        if sym and not sym.startswith(('_Z', '__cxa', '__gxx', '_Unwind')): und[sym] += 1
    for l in subprocess.run([readelf, '-S', '-W', o], capture_output=True, text=True).stdout.splitlines():
        m = re.search(r'\]\s+(__objc\S*|__DATA\S*|\.objc\S*|\.data\.rel\.ro)\s', l)
        if m: secs[m.group(1)] += 1
print(f'\n{len(objs)} objects; undefined symbols that are not C++ library internals ({len(und)}):')
for s_, c in sorted(und.items()): print(f'  {c:3d} {s_}')
print('Objective-C related sections in the objects:', dict(secs))
