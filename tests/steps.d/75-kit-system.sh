#!/bin/sh
# System kits end to end in kitd's system scope (srcpkgs/ribbon-kit/files/lib/system.tcl, plan.tcl; SYSTEM-UPDATES.md
# 7.3-7.7, D57 C / D58 B): tests/kit-system.tcl installs, updates, rewinds and tosses system kits with `kitd --work` on a
# fake root whose /usr is the merged erofs view, with stand-ins for ribbon-snapshot, dinitctl and udevadm. kit-swapmount
# is built here. Runs as root in a private mount namespace; skips (and says why) without root, erofs, util-linux,
# mkfs.erofs, veritysetup or Mk4tcl (KITFMT_MK4TCL). NOT covered: a real snapshot, dinit or udev; the initramfs
# mounting the view at boot; kitd's D-Bus side (tests/kitd.tcl).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip system kits (no tclsh8.6)"; exit 0; fi
if [ "$(id -u)" != 0 ]; then echo "  skip system kits (needs root: loop devices and mounts)"; exit 0; fi
if ! command -v unshare >/dev/null 2>&1 || ! unshare -m --propagation private true 2>/dev/null; then
	echo "  skip system kits (no private mount namespace: unshare -m)"; exit 0
fi
if ! command -v mkfs.erofs >/dev/null 2>&1; then echo "  skip system kits (no mkfs.erofs: erofs-utils is not installed)"; exit 0; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
if ! ${CC:-cc} -O2 -Wall -Wextra -Werror -o "$work/kit-swapmount" srcpkgs/mkkitfs/files/src/swapmount.c 2>"$work/build.log"; then
	cat "$work/build.log"; echo "  FAIL kit-swapmount does not build"; exit 1
fi
KIT_SWAPMOUNT=$work/kit-swapmount timeout -k 5 600 unshare -m --propagation private tclsh8.6 tests/kit-system.tcl ||
	{ echo "  FAIL system kits (tests/kit-system.tcl)"; exit 1; }
