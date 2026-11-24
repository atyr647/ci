#!/bin/sh
# Ribbon's own packages as system kits (build/kits/ribbon-kits.sh): tests/kit-ribbon-kits.tcl builds them in a scratch
# directory, signs and publishes them with the test keys, installs them with `kitd --work` on a fake root and holds the
# merged /usr view to what make install puts into /usr. Runs as root in a private mount namespace; skips (and says why)
# without root, erofs, util-linux, mkfs.erofs, veritysetup, a C compiler or Mk4tcl (KITFMT_MK4TCL).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Ribbon kits (no tclsh8.6)"; exit 0; fi
if [ "$(id -u)" != 0 ]; then echo "  skip Ribbon kits (needs root: loop devices and mounts)"; exit 0; fi
if ! command -v unshare >/dev/null 2>&1 || ! unshare -m --propagation private true 2>/dev/null; then
	echo "  skip Ribbon kits (no private mount namespace: unshare -m)"; exit 0
fi
if ! command -v mkfs.erofs >/dev/null 2>&1; then echo "  skip Ribbon kits (no mkfs.erofs: erofs-utils is not installed)"; exit 0; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Ribbon kits (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$work/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$work/ux" >"$work/make.log" 2>&1 || { cat "$work/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$work/ux
fi
TCLLIBPATH="${ux:+$ux }${TCLLIBPATH:-}"; export TCLLIBPATH
if ! command -v dbus-daemon >/dev/null 2>&1; then echo "  skip Ribbon kits (no dbus-daemon)"; exit 0; fi
if ! ${CC:-cc} -O2 -Wall -Wextra -Werror -o "$work/kit-swapmount" srcpkgs/mkkitfs/files/src/swapmount.c 2>"$work/build.log"; then
	cat "$work/build.log"; echo "  FAIL kit-swapmount does not build"; exit 1
fi
KIT_SWAPMOUNT=$work/kit-swapmount timeout -k 5 900 unshare -m --propagation private tclsh8.6 -encoding utf-8 tests/kit-ribbon-kits.tcl ||
	{ echo "  FAIL Ribbon kits (tests/kit-ribbon-kits.tcl)"; exit 1; }
