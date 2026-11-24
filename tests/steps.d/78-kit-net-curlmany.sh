#!/bin/sh
# kit's chunk download through curl (srcpkgs/ribbon-kit/files/lib/net.tcl, CurlMany): each file capped at its expected size
# by curl itself, oversized ones deleted. tests/kit-net-curlmany.tcl runs real curl against a local server; skips without both.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "  skip kit CurlMany (needs tclsh8.6, curl and python3)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 60 tclsh8.6 -encoding utf-8 tests/kit-net-curlmany.tcl >"$T/out" 2>&1; then
	echo "  ok   kit's parallel https chunk download (curl) caps each file at its expected size ($(grep -c '^  ok ' "$T/out") checks)"
else cat "$T/out"; echo "  FAIL kit's chunk download cap"; exit 1; fi
