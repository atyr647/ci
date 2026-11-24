#!/bin/sh
# kit-updater checks the system's own packages each cycle (srcpkgs/ribbon-kit/files/lib/updater.tcl, systemCheck):
# tests/kit-updater-system.tcl with stand-ins for `ribbon-update --tcl`. Needs no Mk4tcl, network or root; skips
# without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip kit-updater's system check (no tclsh8.6)"
	exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 60 tclsh8.6 -encoding utf-8 tests/kit-updater-system.tcl >"$T/out" 2>&1; then
	echo "  ok   kit-updater checks the system's packages each cycle ($(grep -c '^  ok ' "$T/out") checks)"
else
	cat "$T/out"
	echo "  FAIL kit-updater's system check"
	exit 1
fi
