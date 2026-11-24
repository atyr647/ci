#!/bin/sh
# mkkitfs's reader refuses a kit whose paths are over the limits before building them (a few-MB kit used to need hundreds
# of MB, and gigabytes at a million rows), and `mkkitfs extract` refuses a link chain that leaves the destination
# (tests/mkkitfs-limits.tcl). Needs mkkitfs (on the PATH, or MKKITFS), Mk4tcl (KITFMT_MK4TCL) and /usr/bin/time; skips
# without them.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip mkkitfs's limits (no tclsh8.6)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/mkkitfs-limits.tcl >"$T/out" 2>&1; then
	if grep -q '^  skip' "$T/out"; then sed -n '/^  skip/p' "$T/out"; else echo "  ok   mkkitfs: path limits are checked before paths are built, extract refuses link chains out of the tree ($(grep -c '^  ok ' "$T/out") checks)"; fi
else
	cut -c1-300 "$T/out"; echo "  FAIL mkkitfs's limits"; exit 1
fi
