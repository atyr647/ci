#!/usr/bin/env python3
"""Attributes every byte of a linked half (from the linker map) to a component: which archive member / object it came from, and what that member is
(Dawn backend, Tint piece, SPIRV-Tools, C library ...), decided from the demangled symbols the member defines.
usage: analyze.py <label> <map> <objdir-of-unique-members> [--dump csv]
Prints markdown tables."""
import sys, re, subprocess, glob, os, collections

label, mapf, objdir = sys.argv[1:4]

def cls_of(sec):
    if sec.startswith(('.debug', '.comment', '.GCC', '.zip', '.stab', '.note.GNU')): return 'debug'
    if sec.startswith(('.text', '.init', '.fini', '.plt')): return 'text'
    if sec.startswith('.data.rel.ro') or sec.startswith('.rodata') and False: return 'relro'
    if sec.startswith('.rodata'): return 'rodata'
    if sec.startswith(('.tbss',)): return 'tbss'
    if sec.startswith(('.bss', 'COMMON')): return 'bss'
    if sec.startswith(('.data', '.tdata', '.got')): return 'data'
    if sec.startswith('.eh_frame'): return 'eh_frame'
    if sec.startswith('.gcc_except_table'): return 'except'
    if sec.startswith(('.init_array', '.ctors', '.fini_array', '.preinit')): return 'initarr'
    if sec == '*fill*': return 'fill'
    return 'other'

items = []   # (secname, size, path)
pending = None
started = False
for l in open(mapf, errors='replace'):
    l = l.rstrip('\n')
    if not started:
        started = l.startswith('Linker script and memory map'); continue
    if l.startswith('Cross Reference Table'): break
    if not l.strip(): continue
    if l[0] != ' ':
        pending = None; continue
    m = re.match(r'^ (\S+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S.*)$', l)
    if m:
        pending = None
        if int(m.group(3), 16): items.append((m.group(1), int(m.group(3), 16), m.group(4).strip()))
        continue
    m = re.match(r'^ (\S+)$', l)
    if m: pending = m.group(1); continue
    m = re.match(r'^\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S.*)$', l)
    if m and pending:
        if int(m.group(2), 16): items.append((pending, int(m.group(2), 16), m.group(3).strip()))
        pending = None

# symbols per unique member
RULES = [
 (r'^dawn::native::d3d12::', 'dawn: D3D12 backend'), (r'^dawn::native::d3d::', 'dawn: D3D shared (D3D11/12)'),
 (r'^dawn::native::vulkan::', 'dawn: Vulkan backend'), (r'^dawn::native::metal::', 'dawn: Metal backend'),
 (r'^dawn::native::null::', 'dawn: Null backend'), (r'^dawn::native::opengl::', 'dawn: OpenGL backend'),
 (r'^tint::hlsl::', 'tint: HLSL writer'), (r'^tint::msl::', 'tint: MSL writer'), (r'^tint::glsl::', 'tint: GLSL writer'),
 (r'^tint::spirv::reader', 'tint: SPIR-V reader'), (r'^tint::spirv::', 'tint: SPIR-V writer+dialect'),
 (r'^tint::wgsl::reader', 'tint: WGSL reader (front-end)'), (r'^tint::wgsl::writer', 'tint: WGSL writer'), (r'^tint::wgsl::', 'tint: WGSL language data'),
 (r'^tint::(resolver|ast|sem|program|inspector|core::type|core::constant|core::intrinsic|core::ir|lang|utils|diag|source|symbol|Program|Source|CastableBase|Castable|Slice|Vector|Hashmap|Hashset|Bitset|Result|UniqueVector|SymbolTable|Switch)', 'tint: core (resolver, AST, IR, types)'),
 (r'^tint::', 'tint: other'),
 (r'^(spvtools|spv)::', 'SPIRV-Tools'), (r'^absl::', 'abseil'),
 (r'^(std::|__gnu_cxx|__cxxabiv1|__cxx11|operator new|operator delete)', 'libc++ / C++ runtime'),
 (r'^dawn::native::', 'dawn: native core'), (r'^dawn::', 'dawn: common/utils'),
 (r'^(wgpu|wgpu::)', 'dawn: C API (webgpu)'),
]
RULES = [(re.compile(a), b) for a, b in RULES]
LEAD = re.compile(r'^(?:(?:vtable|typeinfo name|typeinfo|VTT|construction vtable|guard variable|non-virtual thunk|virtual thunk|covariant return thunk|reference temporary #\d+)(?: for| to) )?(?:\(anonymous namespace\)::)?([A-Za-z_0-9:~]+)')
def cat_of_name(n):
    m = LEAD.match(n)
    if not m: return None
    q = m.group(1)
    for rx, c in RULES:
        if rx.search(q): return c
    return 'other:' + '::'.join(q.split('::')[:2])

members = glob.glob(objdir + '/*.o')
sym = collections.defaultdict(lambda: collections.Counter())
sub = collections.defaultdict(lambda: collections.Counter())
CH = 400
for k in range(0, len(members), CH):
    out = subprocess.run(['llvm-nm', '-A', '-S', '--defined-only', '-C'] + members[k:k + CH], capture_output=True, text=True).stdout
    for l in out.split('\n'):
        m = re.match(r'^(.+?\.o):\s*[0-9a-f]+ ([0-9a-f]+) (\w) (.*)$', l)
        if not m: continue
        f, size, t, name = m.group(1), int(m.group(2), 16), m.group(3), m.group(4)
        if size == 0: continue
        c = cat_of_name(name)
        if c is None: continue
        b = os.path.basename(f)
        sym[b][c] += size
        q = LEAD.match(name)
        if q: sub[b]['::'.join(q.group(1).split('::')[:3])] += size

def member_cat(b):
    if re.search(r'Win32Shim|WindowsUtils', b): return 'win32 shim (Win32Shim, UTF-16 helpers)'
    if b in sym and sym[b]:
        return sym[b].most_common(1)[0][0]
    n = b.split('_', 1)[1] if '_' in b else b
    for rx, c in ((r'D3D12', 'dawn: D3D12 backend'), (r'D3D', 'dawn: D3D shared (D3D11/12)'), (r'(VK|Vk|Vulkan)', 'dawn: Vulkan backend'), (r'(MTL|Metal)', 'dawn: Metal backend'), (r'Null', 'dawn: Null backend'),
                  (r'Win32Shim|WindowsUtils', 'win32 shim'), (r'^[0-9]*_?(Tint|tint)', 'tint: other')):
        if re.search(rx, n): return c
    return 'unattributed member'

tot = collections.defaultdict(lambda: collections.Counter())    # category -> class -> bytes
bymem = collections.defaultdict(lambda: collections.Counter())
for sec, size, path in items:
    m = re.match(r'^(.*?)(?:\((.*)\))?$', path)
    arch_or_obj, mem = m.group(1), m.group(2)
    base = os.path.basename(arch_or_obj)
    if mem and re.match(r'^\d{5}_', mem):
        c = member_cat(mem)
    elif 'metal/objs' in path or base.endswith('.mm.o') or (base.startswith(('Backend','Buffer','Device')) and 'MTL' in base):
        c = 'dawn: Metal backend (macOS-built objects)'
    elif 'objc_shim' in path: c = 'Objective-C runtime shim'
    elif base.startswith('wgt.') or base.startswith('gpu_probe') or base.startswith('dawn_bench'): c = 'test application'
    elif base.startswith('tcache'): c = 'per-thread allocator cache'
    elif 'libcxx' in base or 'libc++' in base: c = 'libc++ (cosmocc)'
    elif base.startswith(('libcosmo', 'crt', 'libc')) or 'cosmo' in path: c = 'Cosmopolitan libc + runtime'
    else: c = 'other: ' + base
    k = cls_of(sec)
    tot['other symbols (C names, third-party, misc)' if c.startswith('other:') else c][k] += size
    bymem[(c, mem or base)][k] += size
FILE = ('text', 'rodata', 'relro', 'data', 'eh_frame', 'except', 'initarr', 'other', 'fill')
def fsize(cn): return sum(cn[k] for k in FILE)
print(f'### {label}: bytes in the linked image by component (from the linker map; bss/tbss not counted, they take no file space)')
print('| component | total | text | rodata | data.rel.ro | data | eh_frame+except | other |')
print('|---|---:|---:|---:|---:|---:|---:|---:|')
g = 0
for c in sorted(tot, key=lambda c: -fsize(tot[c])):
    cn = tot[c]; g += fsize(cn)
    print(f'| {c} | {fsize(cn):,} | {cn["text"]:,} | {cn["rodata"]:,} | {cn["relro"]:,} | {cn["data"]:,} | {cn["eh_frame"] + cn["except"]:,} | {cn["initarr"] + cn["other"] + cn["fill"]:,} |')
print(f'| **sum** | **{g:,}** | | | | | | |')
print()
print(f'bss+tbss (memory only): {sum(tot[c]["bss"] + tot[c]["tbss"] for c in tot):,}; debug/non-alloc sections in the unstripped link (not in the shipped file): {sum(tot[c]["debug"] for c in tot):,}')
print()
print(f'### {label}: the 25 biggest objects/members')
rows = sorted(bymem.items(), key=lambda kv: -fsize(kv[1]))[:25]
for (c, mem), cn in rows: print(f'- {fsize(cn):>10,}  {c}  {mem}')
print()
print(f'### {label}: breakdown of the Tint + Dawn core members by dominant namespace (3 levels)')
agg = collections.Counter()
for (c, mem), cn in bymem.items():
    if c.startswith(('tint', 'dawn: native core', 'dawn: common', 'dawn: C API', 'SPIRV')) and mem in sub:
        agg[(c, sub[mem].most_common(1)[0][0])] += fsize(cn)
for (c, ns), v in agg.most_common(45): print(f'- {v:>10,}  {c:36s} {ns}')
if len(sys.argv) > 5 and sys.argv[4] == '--dump':
    import json
    json.dump({c: dict(v) for c, v in tot.items()}, open(sys.argv[5], 'w'))
