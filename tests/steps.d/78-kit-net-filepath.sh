#!/bin/sh
# kit's file:// URLs become paths without Tcl substitution (srcpkgs/ribbon-kit/files/lib/net.tcl, FilePath): a [command]
# in a signed index's root or chunk hash must stay text (it ran as root in kitd before). tests/kit-net-filepath.tcl.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip kit FilePath (no tclsh8.6)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 60 tclsh8.6 -encoding utf-8 tests/kit-net-filepath.tcl >"$T/out" 2>&1; then
	echo "  ok   kit's file:// paths are decoded, never substituted ($(grep -c '^  ok ' "$T/out") checks)"
else cat "$T/out"; echo "  FAIL kit's file:// path decoding"; exit 1; fi
