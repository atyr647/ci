#!/bin/sh
# mkkitfs (srcpkgs/mkkitfs): build it, then run its tests (srcpkgs/mkkitfs/files/tests/run.sh):
# agreement with kitfmt on the golden kits, the damaged ones refused, a fuzz pass, and (where
# /dev/fuse is usable) the session server through FUSE, concurrent reads, start-up time and
# composition.  Skips cleanly when the build tools or libraries are missing.
#
#   METAKIT=<metakit source, kit-fixes>   else the pinned tarball is fetched (not with RIBBON_OFFLINE=1)
#   MKKITFS=<built binary>                skip the build
#   MKKITFS_BENCH=1                       also the cold/warm read benchmark
set -u
cd "$(dirname "$0")/.." || exit 1
pkg=srcpkgs/mkkitfs
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

if [ -z "${MKKITFS:-}" ]; then
	for lib in fuse3 libdeflate libcrypto; do
		if ! pkg-config --exists "$lib" 2>/dev/null; then
			# libdeflate has no .pc file everywhere; its header is enough
			if [ "$lib" = libdeflate ] && [ -f /usr/include/libdeflate.h ]; then continue; fi
			echo "  skip mkkitfs (no $lib development files)"; exit 0
		fi
	done
	command -v "${CXX:-c++}" >/dev/null 2>&1 || { echo "  skip mkkitfs (no C++ compiler)"; exit 0; }
	if [ -z "${METAKIT:-}" ]; then
		if [ "${RIBBON_OFFLINE:-}" = 1 ]; then echo "  skip mkkitfs (offline, and no METAKIT source)"; exit 0; fi
		url=$(sed -n 's/^distfiles="\(.*\)"/\1/p' $pkg/template)
		commit=$(sed -n 's/^_mkcommit=//p' $pkg/template)
		sum=$(sed -n 's/^checksum=//p' $pkg/template)
		url=$(echo "$url" | sed "s/\${_mkcommit}/$commit/")
		if ! curl -fsSL -o "$work/mk.tar.gz" "$url" 2>/dev/null; then echo "  skip mkkitfs (could not fetch $url)"; exit 0; fi
		if [ "$(sha256sum "$work/mk.tar.gz" | cut -d' ' -f1)" != "$sum" ]; then echo "  FAIL mkkitfs: the Metakit tarball does not match the template's checksum"; exit 1; fi
		tar xzf "$work/mk.tar.gz" -C "$work"
		METAKIT=$work/metakit-$commit
	fi
	if ! make -s -C $pkg/files METAKIT="$METAKIT" O="$work/build" -j"$(nproc 2>/dev/null || echo 2)" CXXFLAGS="-O2 -Werror" >"$work/build.log" 2>&1; then
		cat "$work/build.log"; echo "  FAIL mkkitfs does not build"; exit 1
	fi
	echo "  ok   mkkitfs builds with -Wall -Wextra -Werror"
	MKKITFS=$work/build/mkkitfs
fi
MKKITFS=$MKKITFS METAKIT=${METAKIT:-} sh $pkg/files/tests/run.sh
