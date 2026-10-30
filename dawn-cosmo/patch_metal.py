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

# Command buffer handlers: Metal would run them on its own threads, which have none of Cosmopolitan's per-thread state. Hand the committed buffer to a thread
# created by Cosmopolitan instead (MetalCosmo.mm), which waits for it and runs the very same handler bodies. The shader-print log handler is also a callback
# from Metal's threads; it only exists for the EnableShaderPrint toggle (off by default) and is disabled.
def edit(rel, pairs):
    global n
    f = os.path.join(root, rel); s = open(f, errors='surrogateescape').read()
    if 'DawnCosmoMetalWatch' in s:
        print('already patched:', rel); return
    for old, new in pairs:
        assert old in s, (rel, old[:60])
        s = s.replace(old, new, 1)
    open(f, 'w', errors='surrogateescape').write(s); n += 1; print('patched:', rel)
edit('src/dawn/native/metal/QueueMTL.mm', [
    ('namespace dawn::native::metal {\n', '#include <functional>\nvoid DawnCosmoMetalWatch(id<MTLCommandBuffer> commandBuffer, std::function<void(id<MTLCommandBuffer>)> scheduled,\n                         std::function<void(id<MTLCommandBuffer>)> completed);   // MetalCosmo.mm\n\nnamespace dawn::native::metal {\n'),
    ('    [*pendingCommands addScheduledHandler:std::move(ScheduledHandler)];\n    [*pendingCommands addCompletedHandler:std::move(CompletedHandler)];\n', ''),
    ('    [*pendingCommands commit];\n', '    [*pendingCommands commit];\n    DawnCosmoMetalWatch(*pendingCommands, std::move(ScheduledHandler), std::move(CompletedHandler));\n'),
    ('            [mtlLogState addLogHandler:[deviceRef', '            if (false) [mtlLogState addLogHandler:[deviceRef'),
])
