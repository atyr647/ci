#!/usr/bin/env python3
"""Edits to Dawn's Metal sources so they compile as Apple-flavoured translation units inside a Cosmopolitan build (Linux-style integer typedefs: uint64_t is
unsigned long, not Apple's unsigned long long). Idempotent. usage: patch_metal.py <dawn-source-dir>"""
import os, re, sys, glob
root = sys.argv[1]
n = 0
for f in sorted(glob.glob(os.path.join(root, 'src/dawn/native/metal/*.mm')) + glob.glob(os.path.join(root, 'src/dawn/native/metal/*.h'))):
    s = open(f, errors='surrogateescape').read()
    # literals such as 4ull / 0ull / 16ull used with std::max / std::min / templates against uint64_t
    t = re.sub(r'(?<![\w.])(\d+)ull\b', r'static_cast<uint64_t>(\1)', s)
    t = re.sub(r'(?<![\w.])(\d+)ll\b', r'static_cast<int64_t>(\1)', t)
    if t != s:
        open(f, 'w', errors='surrogateescape').write(t); n += 1; print('patched:', os.path.relpath(f, root))
print(n, 'files changed')
