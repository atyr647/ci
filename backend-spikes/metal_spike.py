#!/usr/bin/env python3
"""Spike: how far do Dawn's Metal backend sources get when compiled with the Cosmopolitan toolchain's clang (cosmocc -mclang) as Objective-C++ against the Apple SDK headers?
usage: metal_spike.py <build-dir-with-compile_commands.json> <cosmocc> <sdk-path> [limit]
Prints, per file, OK or the number of errors, then the most common distinct errors. Compiles to a throw-away object; cosmocc builds the x86-64 and arm64 slices."""
import json, re, shlex, subprocess, sys, os, collections
build, cosmocc, sdk = sys.argv[1], sys.argv[2], sys.argv[3]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 10**9
cdb = json.load(open(os.path.join(build, 'compile_commands.json')))
metal = [e for e in cdb if re.search(r'/src/dawn/native/metal/[^/]+\.(mm|cpp)$', e['file'])]
print(f'{len(metal)} translation units in src/dawn/native/metal')
APPLE_DEFS = ['-D__APPLE__=1', '-D__MACH__=1', '-DTARGET_OS_MAC=1', '-DTARGET_OS_OSX=1', '-DTARGET_OS_IPHONE=0', '-DTARGET_OS_SIMULATOR=0', '-DTARGET_CPU_ARM64=1',
              '-DDAWN_COSMO_AS_APPLE=1', '-DOBJC_OLD_DISPATCH_PROTOTYPES=1']
errors = collections.Counter(); examples = {}; results = []
for e in metal[:limit]:
    toks = shlex.split(e['command'])
    keep = []; skip = 0
    for t in toks[1:]:
        if skip: skip -= 1; continue
        if t in ('-o', '-MF', '-MT', '-arch', '-isysroot', '-target', '--target'): skip = 1; continue
        if t in ('-c', '-MD', '-MMD') or t.startswith('-mmacosx-version-min') or t.startswith('-fcolor') or t.startswith('-Werror') or t.startswith('-Wno-') and False: continue
        if t == e['file'] or t.endswith(('.mm', '.cpp')) and t.startswith('/') and os.path.basename(t) == os.path.basename(e['file']): continue
        keep.append(t)
    cmd = [cosmocc, '-mclang', '-c', '-x', 'objective-c++', '-fobjc-arc', '-fblocks', '-fobjc-runtime=macosx', '-Wno-everything'] + APPLE_DEFS + \
          ['-F' + sdk + '/System/Library/Frameworks', '-idirafter' + sdk + '/usr/include'] + keep + [e['file'], '-o', '/tmp/metal_spike.o']
    p = subprocess.run(cmd, capture_output=True, text=True)
    errs = [l for l in p.stderr.splitlines() if ' error:' in l or 'fatal error' in l]
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
