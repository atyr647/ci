#!/usr/bin/env python3
"""A restored Dawn checkout is reset (git checkout) and patched again every run, which gives every patched file a new modification time and makes the build recompile
everything that includes it. This records size/hash/time of the modified and added files before the reset and puts the old time back on every file whose content
came out identical, so only files that really changed are rebuilt.
usage: keep_mtimes.py save|restore <dawn-dir> <state.json>"""
import hashlib, json, os, subprocess, sys
mode, root, state = sys.argv[1:4]
def files():
    out = subprocess.run(['git', '-C', root, 'status', '--porcelain', '--untracked-files=all'], capture_output=True, text=True).stdout
    return [l[3:] for l in out.splitlines() if l[3:]]
def digest(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()
if mode == 'save':
    d = {}
    for f in files():
        p = os.path.join(root, f)
        if os.path.isfile(p): d[f] = [digest(p), os.stat(p).st_mtime_ns]
    json.dump(d, open(state, 'w'))
    print(len(d), 'files recorded')
else:
    if not os.path.exists(state): print('no state'); sys.exit(0)
    d = json.load(open(state)); n = 0
    for f, (h, t) in d.items():
        p = os.path.join(root, f)
        if os.path.isfile(p) and digest(p) == h:
            os.utime(p, ns=(t, t)); n += 1
    print(n, 'of', len(d), 'files got their old modification time back')
