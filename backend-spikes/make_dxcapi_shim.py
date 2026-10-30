#!/usr/bin/env python3
"""Rewrite DXC's dxcapi.h so it compiles against Wine's Windows headers with GCC instead of DXC's own Linux type adapter (which defines the same Windows types differently).
usage: make_dxcapi_shim.py <in dxcapi.h> <out dxcapi.h>"""
import re, sys
s = open(sys.argv[1]).read()
# 1. header prologue: no dllimport, Windows branch, our own UUID macro
a = s.index('#ifdef _WIN32\n#ifndef DXC_API_IMPORT'); b = s.index('struct IMalloc;')
s = s[:a] + '#include <windows.h>\n#ifndef DXC_API_IMPORT\n#define DXC_API_IMPORT\n#endif\n\n' + s[b:]
# 2. GUID declarations
def guid(m):
    name, g = m.group(1), m.group(2).replace('-', '')
    f = [g[0:8], g[8:12], g[12:16]] + [g[16 + 2*i:18 + 2*i] for i in range(8)]
    return f'struct {name}; __CRT_UUID_DECL({name}, 0x{f[0]}, 0x{f[1]}, 0x{f[2]}, ' + ', '.join('0x' + x for x in f[3:]) + ')'
s = re.sub(r'CROSS_PLATFORM_UUIDOF\(\s*(\w+)\s*,\s*"([0-9A-Fa-f-]{36})"\s*\)', guid, s)
# 3. the remaining Windows-only blocks are wanted
s = s.replace('#ifdef _WIN32\n', '#if 1\n')
open(sys.argv[2], 'w').write(s)
print('wrote', sys.argv[2], 'GUID declarations:', len(re.findall(r'__CRT_UUID_DECL', s)))
