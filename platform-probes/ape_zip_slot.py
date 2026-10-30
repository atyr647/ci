#!/usr/bin/env python3
"""Make the Authenticode certificate table and the embedded zip coexist with a zip whose end-of-central-directory record is still the LAST thing in the file.

Normal signing appends the certificate table after the file's last byte, i.e. after the zip's end-of-central-directory (EOCD) record. Zip readers that look for the EOCD
at a fixed distance from the end of the file (and strict ones that require EOCD + comment length == end of file) then fail. This tool reserves a slot instead:
  step 1  reserve  IN OUT SIZE   pad the file to 8 bytes, set the EOCD comment length so the comment covers pad + SIZE bytes that are NOT yet in the file
                                 (the file is truncated on purpose; it exists only to be hashed/signed). The signer then appends the certificate table
                                 exactly there, at the end, as it always does.
  step 2  fill     SIGNED OUT SIZE  take the signed file, rewrite the WIN_CERTIFICATE length to SIZE and zero-fill, so the certificate table occupies precisely the
                                 bytes the EOCD comment claims: file end == EOCD + 22 + comment length. Authenticode excludes the certificate table (and the PE checksum
                                 and the certificate-table directory entry) from the hash, and the EOCD comment length is part of what was hashed in step 1, so the
                                 signature stays valid.
The padding after the PKCS#7 blob inside the certificate table is zero bytes (signers already pad to 8; this only makes the pad longer)."""
import struct, sys

def pe_info(d):
    lf = struct.unpack_from('<I', d, 0x3c)[0]
    assert d[lf:lf + 4] == b'PE\0\0', 'no PE header at e_lfanew'
    o = lf + 24
    assert struct.unpack_from('<H', d, o)[0] == 0x20b and struct.unpack_from('<I', d, o + 108)[0] >= 5, 'need a PE32+ header with >= 5 data directories (run pe_prepare_for_signing.py)'
    return o

def pe_checksum(d, ck_off):
    s = 0; n = len(d)
    buf = bytes(d) + b'\0' * (n & 1)
    for i in range(0, len(buf), 2):
        if ck_off <= i < ck_off + 4: continue
        s += buf[i] | (buf[i + 1] << 8)
        s = (s & 0xffff) + (s >> 16)
    s = (s & 0xffff) + (s >> 16)
    return (s + n) & 0xffffffff

def eocd(d):
    e = d.rfind(b'PK\x05\x06'); assert e >= 0, 'no zip end-of-central-directory record'
    return e

def reserve(inp, out, size):
    d = bytearray(open(inp, 'rb').read()); o = pe_info(d)
    assert struct.unpack_from('<II', d, o + 112 + 32) == (0, 0), 'already has a certificate table'
    e = eocd(d); old = struct.unpack_from('<H', d, e + 20)[0]
    assert e + 22 + old == len(d), 'EOCD record is not at the very end of the file'
    pad = (-len(d)) % 8; d += b'\0' * pad
    assert size % 8 == 0 and old + pad + size <= 0xffff
    struct.pack_into('<H', d, e + 20, old + pad + size)
    open(out, 'wb').write(d); print(f'reserved: slot for the certificate table will start at {len(d):#x}, {size} bytes; EOCD comment length set to {old + pad + size}')

def fill(inp, out, size):
    d = bytearray(open(inp, 'rb').read()); o = pe_info(d)
    off, sz = struct.unpack_from('<II', d, o + 112 + 32); assert off and sz, 'file has no certificate table'
    assert off + sz == len(d), 'certificate table is not at the end'
    dwlen, rev, typ = struct.unpack_from('<IHH', d, off); assert dwlen <= sz and typ == 2
    p7 = bytes(d[off + 8:off + dwlen])
    assert 8 + len(p7) <= size, f'signature ({8 + len(p7)} bytes) does not fit the reserved slot ({size})'
    print('osslsigncode-style checksum reproduced by this tool:', pe_checksum(d, o + 64) == struct.unpack_from('<I', d, o + 64)[0])
    new = bytearray(d[:off]) + struct.pack('<IHH', size, rev, typ) + p7; new += b'\0' * (off + size - len(new))
    struct.pack_into('<II', new, o + 112 + 32, off, size)
    struct.pack_into('<I', new, o + 64, pe_checksum(new, o + 64))
    e = eocd(new); assert e + 22 + struct.unpack_from('<H', new, e + 20)[0] == len(new), 'EOCD comment does not end at end of file'
    open(out, 'wb').write(new)
    print(f'filled: certificate table at {off:#x}, {size} bytes of which {8 + len(p7)} are the signature; EOCD at {e:#x}, its comment ends at the end of the file')

if __name__ == '__main__':
    {'reserve': reserve, 'fill': fill}[sys.argv[1]](sys.argv[2], sys.argv[3], int(sys.argv[4]))
