#!/bin/sh
# mkkitfs's reader under AddressSanitizer and UndefinedBehaviorSanitizer (KIT-round2.md 2.4: "continuous fuzzing
# under ASan/UBSan in CI"): `make fuzz` builds mkkitfs and Metakit with -fsanitize=address,undefined and runs
# tests/fuzz-sanitize.sh: MKKITFS_FUZZ_SANITIZE damaged kits (default 3000) through the confined reader, then a
# fifth of that unconfined with LeakSanitizer. Built from KIT_METAKIT_TARBALL, the Metakit tarball the template
# names (checked against its sha256), as tests/run.sh builds mkkitfs: the CI check job sets it; without it this
# skips. MKKITFS_FUZZ_SEED picks the seed (CI's scheduled run varies it).
set -u
cd "$(dirname "$0")/../.." || exit 1
pkg=srcpkgs/mkkitfs
if [ -z "${KIT_METAKIT_TARBALL:-}" ] || [ ! -f "${KIT_METAKIT_TARBALL:-}" ]; then
	echo "  skip mkkitfs sanitizer fuzz pass (no KIT_METAKIT_TARBALL: it is built in CI)"; exit 0
fi
for lib in fuse3 libcrypto; do
	pkg-config --exists "$lib" 2>/dev/null || { echo "  skip mkkitfs sanitizer fuzz pass (no $lib development files)"; exit 0; }
done
[ -f /usr/include/libdeflate.h ] || pkg-config --exists libdeflate 2>/dev/null || { echo "  skip mkkitfs sanitizer fuzz pass (no libdeflate)"; exit 0; }
commit=$(sed -n 's/^_mkcommit=//p' $pkg/template)
sum=$(sed -n 's/^checksum=//p' $pkg/template)
if [ "$(sha256sum "$KIT_METAKIT_TARBALL" | cut -d' ' -f1)" != "$sum" ]; then
	echo "  skip mkkitfs sanitizer fuzz pass ($KIT_METAKIT_TARBALL is not the tarball the template names)"; exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
tar xzf "$KIT_METAKIT_TARBALL" -C "$work" || { echo "  FAIL the Metakit tarball does not unpack"; exit 1; }
if ! make -s -C $pkg/files METAKIT="$work/metakit-$commit" O="$work/build" -j"$(nproc 2>/dev/null || echo 2)" \
	FUZZ="${MKKITFS_FUZZ_SANITIZE:-3000}" SEED="${MKKITFS_FUZZ_SEED:-1}" fuzz >"$work/fuzz.log" 2>&1; then
	tail -60 "$work/fuzz.log"; echo "  FAIL mkkitfs sanitizer fuzz pass"; exit 1
fi
grep -E '^  (ok|FAIL|skip) ' "$work/fuzz.log"
