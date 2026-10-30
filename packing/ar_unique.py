#!/usr/bin/env python3
"""Splits a GNU ar archive into one file per member, named <index>_<member>, so that duplicate member names (Dawn has many) stay distinguishable in a linker map.
usage: ar_unique.py <archive.a> <outdir>"""
import sys, os
d = open(sys.argv[1], 'rb').read()
out = sys.argv[2]; os.makedirs(out, exist_ok=True)
assert d[:8] == b'!<arch>\n'
i = 8; longnames = b''; n = 0
while i + 60 <= len(d):
    h = d[i:i + 60]; name = h[:16].decode('latin1').strip(); size = int(h[48:58]); i += 60
    data = d[i:i + size]; i += size + (size & 1)
    if name == '/' or name.startswith('/SYM') or name == '__.SYMDEF':
        continue
    if name == '//':
        longnames = data; continue
    if name.startswith('/') and name[1:].isdigit():
        off = int(name[1:]); end = longnames.index(b'\n', off); name = longnames[off:end].decode('latin1').rstrip('/')
    elif name.endswith('/'):
        name = name[:-1]
    name = name.replace('/', '_')
    open(os.path.join(out, '%05d_%s' % (n, name)), 'wb').write(data); n += 1
print('members:', n)
