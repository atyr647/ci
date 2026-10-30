#!/bin/bash
# Does a ONE-PLACE change in Cosmopolitan's ape/ape.S (emit 16 PE data directories instead of 2) make the linked file signable by Microsoft's / osslsigncode's tools as-is?
# cwd = repo root, ./cosmo = cosmocc 4.0.2 (the release). Builds ape.o from the 4.0.2 sources unpatched (and compares it with the shipped one: same recipe?) and patched, links a test program with the
# patched object, checks the PE header and signs the result WITHOUT pe_prepare_for_signing.py.
set +e
V=4.0.2
curl -fsSL -o src.tgz https://github.com/jart/cosmopolitan/archive/refs/tags/$V.tar.gz && mkdir src && tar xzf src.tgz -C src --strip-components=1 && echo "sources unpacked"
cd src
echo "--- build ape.o and friends from the unpatched sources"
make -j$(nproc) o//ape/ape.o o//ape/ape-no-modify-self.o o//ape/ape-copy-self.o o//ape/ape.lds 2>&1 | tail -15
ls -la o//ape/*.o o//ape/ape.lds 2>&1 | head
for f in ape.o ape-no-modify-self.o ape.lds; do
  if cmp -s o//ape/$f ../cosmo/x86_64-linux-cosmo/lib/$f; then echo "RESULT built $f is byte-identical to the shipped one"; else echo "RESULT built $f differs from the shipped one: $(stat -c %s o//ape/$f 2>&1) vs $(stat -c %s ../cosmo/x86_64-linux-cosmo/lib/$f)"; fi
done
mkdir -p ../unpatched && cp o//ape/ape.o o//ape/ape-no-modify-self.o o//ape/ape.lds ../unpatched/ 2>/dev/null
python3 - <<'PY'
p = 'ape/ape.S'; s = open(p).read()
old = """	.long	2			// NumberOfDirectoryEntries
	.long	0,0			// ExportsDirectory
	.long	ape_idata		// ImportsDirectory
	.long	ape_idata_idtsize	// ImportsDirectorySize
"""
new = """	.long	16			// NumberOfDirectoryEntries (was 2): room for the certificate table (index 4)
	.long	0,0			// ExportsDirectory
	.long	ape_idata		// ImportsDirectory
	.long	ape_idata_idtsize	// ImportsDirectorySize
	.fill	14,8,0			// directories 2..15 empty (index 4 = Authenticode certificate table)
"""
assert old in s; open(p, 'w').write(s.replace(old, new)); print('patched ape/ape.S')
PY
rm -f o//ape/ape.o o//ape/ape-no-modify-self.o o//ape/ape-copy-self.o
echo "--- rebuild with the patch"
make -j$(nproc) o//ape/ape.o o//ape/ape-no-modify-self.o o//ape/ape-copy-self.o o//ape/ape.lds 2>&1 | tail -8
cd ..
echo "--- link with the patched objects (copy of the cosmocc tree, shipped ape objects replaced)"
cp -r cosmo cosmo-patched
for f in ape.o ape-no-modify-self.o ape-copy-self.o; do [ -f src/o//ape/$f ] && cp src/o//ape/$f cosmo-patched/x86_64-linux-cosmo/lib/$f; done
cp src/o//ape/ape.lds cosmo-patched/x86_64-linux-cosmo/lib/ape.lds
mkdir -p up
cosmo-patched/bin/cosmocc -O2 platform-probes/app.c -o up/app.com 2>&1 | tail -5
echo signed-test-asset > asset.txt; zip -q -A up/app.com asset.txt
python3 - <<'PY'
import struct
d = open('up/app.com', 'rb').read(); lf = struct.unpack_from('<I', d, 0x3c)[0]; o = lf + 24
print('RESULT patched build: PE header at', hex(lf), '; SizeOfOptionalHeader =', struct.unpack_from('<H', d, lf + 20)[0], '; NumberOfRvaAndSizes =', struct.unpack_from('<I', d, o + 108)[0], '; section table follows at', hex(o + struct.unpack_from('<H', d, lf + 20)[0]))
PY
sh ./up/app.com | sed 's/^/RESULT patched build runs on Linux: /'
sudo apt-get install -y osslsigncode >/dev/null 2>&1
bash platform-probes/signing/pki.sh pki >/dev/null
osslsigncode sign -certs pki/leaf-chain.pem -key pki/leaf.key -h sha256 -in up/app.com -out up/app-signed.exe 2>&1 | tail -2 | sed 's/^/RESULT osslsigncode on the patched build (no preparation): /'
osslsigncode verify -in up/app-signed.exe -CAfile pki/root.pem 2>&1 | grep -i 'signature verification' | sed 's/^/RESULT osslsigncode verify: /'
sh ./up/app-signed.exe | sed 's/^/RESULT signed patched build runs on Linux: /'
cp up/app.com up/app-ps.exe
mkdir -p up-out; cp up/app.com up/app-signed.exe up-out/; cp -r pki up-out/
