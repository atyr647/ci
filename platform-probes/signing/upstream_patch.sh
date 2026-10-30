#!/bin/bash
# Does a ONE-PLACE change in Cosmopolitan's ape/ape.S (emit 16 PE data directories instead of 2) make the linked file signable by Microsoft's/osslsigncode's tools as-is?
# cwd = repo root, ./cosmo = cosmocc 4.0.2. Builds a patched ape.o from the 4.0.2 sources, links a test program with it, checks the PE header and tries to sign it.
set +e
V=4.0.2
echo "--- where does cosmocc keep the pieces apelink/ld use?"
find cosmo -name 'ape*' -not -name '*.md' | head -20
ls cosmo cosmo/bin | head -60
curl -fsSL -o src.tgz https://github.com/jart/cosmopolitan/archive/refs/tags/$V.tar.gz && mkdir src && tar xzf src.tgz -C src --strip-components=1 && echo "sources: $(du -sh src | cut -f1)"
grep -n "NumberOfDirectoryEntries" -A4 src/ape/ape.S | head -12
python3 - <<'PY'
p = 'src/ape/ape.S'; s = open(p).read()
old = """	.long	2			// NumberOfDirectoryEntries
	.long	0,0			// ExportsDirectory
	.long	ape_idata		// ImportsDirectory
	.long	ape_idata_idtsize	// ImportsDirectorySize
"""
new = """	.long	16			// NumberOfDirectoryEntries (was 2): room for the certificate table (index 4)
	.long	0,0			// ExportsDirectory
	.long	ape_idata		// ImportsDirectory
	.long	ape_idata_idtsize	// ImportsDirectorySize
	.fill	14,8,0			// directories 2..15 empty, index 4 = Authenticode certificate table
"""
assert old in s; open(p, 'w').write(s.replace(old, new)); print('patched')
PY
cd src
# how does the Makefile build ape.o ?
grep -n "ape.o\|APE_" ape/ape.mk 2>/dev/null | head -20
cd ..
