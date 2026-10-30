#!/usr/bin/env python3
"""Run in the Linux arm64 Cosmopolitan build of Dawn. Writes what the macOS job needs to compile Dawn's Metal sources with EXACTLY the definitions and include
paths the rest of that Dawn build uses (the C++ classes the Metal objects share with the rest of Dawn must have identical layouts):
  flags.json   the compile flags of one Dawn native translation unit (definitions, include paths, language options), build-directory paths replaced by @ROOT@
  inputs.tar.gz  every header (and .inc/.def) below the include paths, plus the Metal sources, relative to the repository root
usage: export_inputs.py <repo-root> <build-dir> <out-dir>"""
import json, os, shlex, sys, tarfile
root, build, out = [os.path.abspath(a) for a in sys.argv[1:4]]
os.makedirs(out, exist_ok=True)
cdb = json.load(open(os.path.join(build, 'compile_commands.json')))
entry = next(e for e in cdb if e['file'].endswith('src/dawn/native/vulkan/QueueVk.cpp'))
toks = shlex.split(entry['command'])[1:]
keep, dirs, skip = [], [], 0
for i, t in enumerate(toks):
    if skip: skip -= 1; continue
    if t == '-isystem' and i + 1 < len(toks):
        keep += [t, toks[i + 1]]; dirs.append(toks[i + 1]); skip = 1; continue
    if t.startswith('-I'):
        keep.append(t); dirs.append(t[2:]); continue
    if t.startswith(('-D', '-std=')) or t in ('-fno-exceptions', '-fno-rtti', '-fPIC') or t.startswith('-O') or t.startswith('-fvisibility'):
        keep.append(t)
flags = json.loads(json.dumps(keep).replace(root, '@ROOT@'))
assert any(f.startswith('-DTINT_BUILD_MSL_WRITER=1') for f in flags), 'the Tint MSL writer must be enabled in this build (the Metal backend uses it)'
json.dump(flags, open(os.path.join(out, 'flags.json'), 'w'), indent=1)
HDR = ('.h', '.hpp', '.hh', '.inc', '.inl', '.def', '.ipp')
n = 0; seen = set()
with tarfile.open(os.path.join(out, 'inputs.tar.gz'), 'w:gz') as tf:
    for d in dirs:
        d = os.path.abspath(d)
        if not d.startswith(root): continue
        for dp, dn, fn in os.walk(d):
            if '/.git' in dp: continue
            for f in fn:
                p = os.path.join(dp, f)
                if f.endswith(HDR) and p not in seen:
                    seen.add(p); tf.add(p, arcname=os.path.relpath(p, root)); n += 1
    for f in ('IOSurfaceUtils.cpp', 'SystemUtils_mac.mm'):
        p = os.path.join(root, 'dawn/src/dawn/common', f); tf.add(p, arcname=os.path.relpath(p, root)); n += 1
    mdir = os.path.join(root, 'dawn/src/dawn/native/metal')
    for f in sorted(os.listdir(mdir)):
        p = os.path.join(mdir, f)
        if f.endswith(('.mm', '.cpp', '.h')) and p not in seen:
            seen.add(p); tf.add(p, arcname=os.path.relpath(p, root)); n += 1
print(f'{len(flags)} flags, {n} files, {os.path.getsize(os.path.join(out, "inputs.tar.gz")) // 1024} KiB')
