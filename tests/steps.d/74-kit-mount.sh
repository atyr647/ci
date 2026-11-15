#!/bin/sh
# System kits as one merged erofs /usr view and its atomic live switch (srcpkgs/ribbon-kit/files/lib/mount.tcl,
# D57 C / D58 B, SYSTEM-UPDATES.md 8.3): tests/kit-mount.tcl packs system kits around plain erofs images, builds
# the view, switches it live under a process holding the old one and a watcher stat-ing paths in a tight loop,
# and checks refusals, pruning and restore. kit-swapmount (srcpkgs/mkkitfs/files/src/swapmount.c) is built here
# with -Werror. Runs as root in a private mount namespace; skips (and says why) without root, erofs, util-linux's
# losetup, mkfs.erofs, veritysetup or Mk4tcl (KITFMT_MK4TCL).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip merged /usr view (no tclsh8.6)"; exit 0; fi
if [ "$(id -u)" != 0 ]; then echo "  skip merged /usr view (needs root: loop devices and mounts)"; exit 0; fi
if ! command -v unshare >/dev/null 2>&1 || ! unshare -m --propagation private true 2>/dev/null; then
	echo "  skip merged /usr view (no private mount namespace: unshare -m)"; exit 0
fi
if ! command -v mkfs.erofs >/dev/null 2>&1; then echo "  skip merged /usr view (no mkfs.erofs: erofs-utils is not installed)"; exit 0; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
if ! ${CC:-cc} -O2 -Wall -Wextra -Werror -o "$work/kit-swapmount" srcpkgs/mkkitfs/files/src/swapmount.c 2>"$work/build.log"; then
	cat "$work/build.log"; echo "  FAIL kit-swapmount does not build"; exit 1
fi
echo "  ok   kit-swapmount builds with -Wall -Wextra -Werror"
KIT_SWAPMOUNT=$work/kit-swapmount timeout -k 5 300 unshare -m --propagation private tclsh8.6 tests/kit-mount.tcl ||
	{ echo "  FAIL merged /usr view (tests/kit-mount.tcl)"; exit 1; }
