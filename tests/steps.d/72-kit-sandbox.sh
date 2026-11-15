#!/bin/sh
# kit run's sandbox (srcpkgs/ribbon-kit/files/lib/sandbox.tcl, launch.tcl; docs/KIT.md D6 C): tests/kit-sandbox.tcl
# reads Properties' grants file back, merges it over a kit's request, checks the bubblewrap command, then launches a
# fixture kit in bubblewrap: a folder not granted is invisible, read-only grants can't be written, grants widen and
# narrow, no network unless granted, private $HOME, kit's own state hidden, nested namespaces only when granted, the
# bus only through xdg-dbus-proxy (a stand-in here), the System monitor naming the sandbox after the kit, and with
# FUSE + mkkitfs + Mk4tcl (KITFMT_MK4TCL) kit run of a packed .kit. kit-landlock (files/landlock) is built here with
# -Werror and its checks run where the kernel has Landlock. Skips without tclsh8.6 or bubblewrap.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
	echo "  skip kit sandbox (no tclsh8.6 / bwrap)"
	exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
status=0
if command -v "${CC:-cc}" >/dev/null 2>&1; then
	if make -s -C srcpkgs/ribbon-kit/files/landlock O="$work" CFLAGS="-O2 -Werror" >"$work/build.log" 2>&1; then
		echo "  ok   kit-landlock builds with -Wall -Wextra -Werror"
		KIT_LANDLOCK=$work/kit-landlock; export KIT_LANDLOCK
	else
		cat "$work/build.log"; echo "  FAIL kit-landlock does not build"; status=1
	fi
else
	echo "  skip building kit-landlock (no C compiler): the Landlock checks skip"
fi
timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/kit-sandbox.tcl || { echo "  FAIL kit sandbox (tests/kit-sandbox.tcl)"; status=1; }
exit $status
