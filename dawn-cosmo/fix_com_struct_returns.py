#!/usr/bin/env python3
"""MIDL-generated C++ interface declarations return structs by value (D3D12_RESOURCE_ALLOCATION_INFO GetResourceAllocationInfo(...), D3D12_CPU_DESCRIPTOR_HANDLE
GetCPUDescriptorHandleForHeapStart(), GetDesc(), GetCustomHeapProperties(), GetAdapterLuid() ...). Microsoft's compiler passes the hidden result pointer SECOND for such
member functions (this in RCX, result pointer in RDX - the "RetVal" parameter of the C binding); GCC's ms_abi passes it FIRST, so every call to one of these methods from
GCC-compiled code arrives with the two swapped and crashes inside the D3D12 runtime (measured: access violation in D3D12Core.dll from
ResourceAllocatorManager::CreatePlacedResource -> GetResourceAllocationInfo).
Rewrite each such virtual as the real binary form  `virtual T *Name(T *RetVal, args) = 0;`  plus an inline by-value wrapper `T Name(args)`, which keeps every caller's source unchanged.
usage: fix_com_struct_returns.py <header-dir>   (rewrites d3d12*.h in place)"""
import re, sys, glob, os
d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, 'd3d12*.h')) + glob.glob(os.path.join(d, 'd3dcommon.h')))
text = {f: open(f, errors='surrogateescape').read() for f in files}
alltext = '\n'.join(text.values())
structs = set(re.findall(r'typedef\s+struct\s+\w*\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}\s*(\w+)\s*;', alltext, re.S))
structs |= set(re.findall(r'typedef\s+struct\s+(\w+)\s+(\w+)\s*;', alltext) and [b for a, b in re.findall(r'typedef\s+struct\s+(\w+)\s+(\w+)\s*;', alltext)])
structs |= {'LUID'}
decl = re.compile(r'(?P<ind>[ \t]*)virtual\s+(?P<ret>[A-Za-z_]\w*)\s+STDMETHODCALLTYPE\s+(?P<name>\w+)\(\s*(?P<args>[^;]*?)\)\s*=\s*0;', re.S)
def names(args):
    a = re.sub(r'_\w+_\([^()]*\)', ' ', args)            # SAL with arguments
    a = re.sub(r'\b_\w+_\b', ' ', a)                       # SAL without
    a = re.sub(r'/\*.*?\*/', ' ', a, flags=re.S)
    a = a.strip()
    if a in ('', 'void'): return ''
    parts, depth, cur = [], 0, ''
    for ch in a:
        if ch == ',' and depth == 0: parts.append(cur); cur = ''
        else:
            depth += ch in '(<['; depth -= ch in ')>]'; cur += ch
    parts.append(cur)
    out = []
    for p in parts:
        p = re.sub(r'\[[^\]]*\]', '', p).strip()
        m = re.search(r'(\w+)\s*$', p)
        out.append(m.group(1))
    return ', '.join(out)
total = 0
for f, t in text.items():
    count = 0
    def rep(m):
        global total
        global count
        ret, name = m.group('ret'), m.group('name')
        if ret not in structs: return m.group(0)
        args = re.sub(r'\s+', ' ', m.group('args').strip())
        argnames = names(args)
        ind = m.group('ind')
        has_args = args not in ('', 'void')
        sig_args = ('%s *RetVal' % ret) + (', ' + args if has_args else '')
        call_args = '&r' + (', ' + argnames if has_args else '')
        total += 1
        return (f'{ind}virtual {ret} *STDMETHODCALLTYPE {name}({sig_args}) = 0;   /* real ABI: result pointer second (see fix_com_struct_returns.py) */\n'
                f'{ind}{ret} {name}({args if has_args else ""}) {{ {ret} r; {name}({call_args}); return r; }}')
    t2 = decl.sub(rep, t)
    if t2 != t:
        open(f, 'w', errors='surrogateescape').write(t2); print('rewritten:', os.path.basename(f))
print(total, 'methods rewritten')
