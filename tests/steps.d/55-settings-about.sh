#!/bin/sh
# Settings → About (the backend, apps/settings/about.tcl) with no display (tests/settings-about.tcl): the model read
# from a fake root (os-release, /proc, /sys, /etc), stand-ins for labwc, df and stat, a small pci.ids and kit's cache
# file: the board's machine row by row, then each source missing, damaged or different; the name changed through a
# stub pkexec and the real ribbon-hostname-helper on the fake root (done, cancelled, refused, no pkexec); and the real
# machine against uname, df, stat, labwc and the system's pci.ids where they are there.
# Skips without tclsh8.6. NOT covered: a real polkit prompt, a real change of the name, the page itself
# (57-settings-about-page.sh), the helper's own checks (56-settings-hostname-helper.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → About (no tclsh8.6)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
if env TMPDIR="$T" timeout -k 5 150 tclsh8.6 -encoding utf-8 tests/settings-about.tcl "$D" >"$T/about.out" 2>&1; then
	grep -v '^  ok ' "$T/about.out" | grep -v '^about: all checks passed$' | sed 's/^/     /'
	echo "  ok   Settings → About: the backend ($(grep -c '^  ok ' "$T/about.out") checks: a fake root, the helper behind a stub pkexec, the real machine)"
else
	cat "$T/about.out"
	echo "  FAIL Settings → About: the backend"
	exit 1
fi
