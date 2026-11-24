#!/bin/sh
# mkkitfs's confinement on its own (srcpkgs/mkkitfs/files/src/confine.cpp; MKKITFS.md 10, KIT-round2.md 2.4
# item 4): tests/confine-test.cpp applies each profile (reader, extract, server) in a child and checks what it
# allows (reading, extract's own directory, threads, the server's own checker) and refuses (writes, sockets,
# mount, ptrace, unshare, bpf, clone3, namespaces through clone, other programs, signals outside the domain);
# as root in a private mount namespace also the unmount guard (a killed, confined server's mount goes). No
# Metakit or FUSE needed, so it runs where mkkitfs itself can't be built (tests/test-mkkitfs.sh runs the same
# program inside mkkitfs's own tests, beside the confined FUSE server).
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v "${CXX:-c++}" >/dev/null 2>&1 || { echo "  skip mkkitfs confinement (no C++ compiler)"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
f=srcpkgs/mkkitfs/files
if ! ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -Werror -o "$work/confine-test" \
	$f/tests/confine-test.cpp $f/src/confine.cpp -lpthread 2>"$work/build.log"; then
	cat "$work/build.log"; echo "  FAIL confine-test does not build"; exit 1
fi
mkdir -p "$work/w"
if [ "$(id -u)" = 0 ] && command -v unshare >/dev/null 2>&1 && unshare -m --propagation private true 2>/dev/null; then
	CONFINE_TEST_MOUNT=1 timeout -k 5 120 unshare -m --propagation private "$work/confine-test" "$work/w"
else
	timeout -k 5 120 "$work/confine-test" "$work/w"
fi || { echo "  FAIL mkkitfs confinement (tests/confine-test.cpp)"; exit 1; }
# the Makefile: `make` builds and installs nothing; `make install` installs mkkitfs, kit-swapmount and the rest
mk() { make -s -n -f $f/Makefile O="$work/o" DESTDIR="$work/d" -o "$work/o/mkkitfs" -o "$work/o/kit-swapmount" "$@" 2>&1; }
if mk all | grep -q 'install '; then echo "  FAIL make (all) runs the install recipe"; mk all; exit 1; fi
inst=$(mk install)
for p in bin/mkkitfs lib/ribbon/kit/kit-swapmount bin/mkkitfsd lib/mkkitfs1.0/mkkitfs.tcl lib/dinit.d/user/mkkitfs; do
	case "$inst" in *"$work/d/usr/$p"*) ;; *) echo "  FAIL make install does not install $p"; echo "$inst"; exit 1 ;; esac
done
echo "  ok   make builds only; make install installs mkkitfs, kit-swapmount, mkkitfsd and the Tcl package"
