#!/usr/bin/env python3
"""A Cosmopolitan program is also a valid Windows PE file, but its PE header lists only 2 data directories (NumberOfRvaAndSizes = 2) in a 128-byte optional header, and a
Mach-O header follows it immediately. Authenticode signing needs the 5th directory (the certificate table), so signing tools refuse the file. This writes a second copy of
the PE header with the standard 16 directories (optional header 240 bytes) into unused zero padding earlier in the headers and points e_lfanew at it. Nothing else changes.
usage: pe_prepare_for_signing.py in out"""
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
lf = struct.unpack_from('<I', d, 0x3c)[0]
assert d[lf:lf + 4] == b'PE\0\0'
ns = struct.unpack_from('<H', d, lf + 6)[0]; opt = struct.unpack_from('<H', d, lf + 20)[0]; o = lf + 24
assert struct.unpack_from('<H', d, o)[0] == 0x20b and opt == 128
assert struct.unpack_from('<I', d, o + 108)[0] == 2
old_secs = bytes(d[o + opt:o + opt + ns * 40])
hdr = bytearray(d[lf:o + 112 + 16])            # signature + file header + optional header up to the data directories (2 present)
hdr += b'\0' * (128 - 16)                      # 16 directories in total
struct.pack_into('<I', hdr, 24 + 108, 16)      # NumberOfRvaAndSizes
struct.pack_into('<H', hdr, 20, 240)           # SizeOfOptionalHeader
new = bytes(hdr[:24 + 112]) + bytes(d[o + 112:o + 112 + 16]) + b'\0' * 112 + old_secs   # keep the two existing directory entries
assert len(new) == 24 + 240 + ns * 40, len(new)
# find zero padding for it (aligned to 8, inside the headers)
at = None
for cand in range(0x1000, 0x10000, 8):
    if not any(d[cand:cand + len(new)]): at = cand; break
assert at, 'no free space'
d[at:at + len(new)] = new
struct.pack_into('<I', d, 0x3c, at)
open(sys.argv[2], 'wb').write(d)
print(f'new PE header at {at:#x} (old one at {lf:#x}): {ns} sections, optional header 240 bytes, 16 data directories')
