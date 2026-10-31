# prints the memory import/definition limits of a wasm module (initial, maximum, shared) - enough to see what a threads guest asks the host for
import sys
b = open(sys.argv[1], 'rb').read(); p = 8
def leb(p):
    r = s = 0
    while True:
        x = b[p]; p += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r, p
def limits(p):
    fl, p = leb(p); mn, p = leb(p); mx = None
    if fl & 1: mx, p = leb(p)
    return fl, mn, mx, p
while p < len(b):
    sid = b[p]; p += 1; sz, p = leb(p); end = p + sz
    if sid == 2:
        n, q = leb(p)
        for _ in range(n):
            l, q = leb(q); mod = b[q:q + l].decode(); q += l; l, q = leb(q); nm = b[q:q + l].decode(); q += l; kind = b[q]; q += 1
            if kind == 2:
                fl, mn, mx, q = limits(q); print(f'import memory {mod}.{nm}: initial {mn} pages ({mn * 64} KiB), maximum {mx}, shared={bool(fl & 2)}')
            elif kind == 0: _, q = leb(q)
            elif kind == 1: q += 1; _, _, _, q = limits(q)
            elif kind == 3: q += 2
    if sid == 5:
        n, q = leb(p)
        for _ in range(n):
            fl, mn, mx, q = limits(q); print(f'defined memory: initial {mn} pages, maximum {mx}, shared={bool(fl & 2)}')
    p = end
