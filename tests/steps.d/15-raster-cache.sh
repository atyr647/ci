#!/bin/sh
# The shell's raster cache keys (srcpkgs/ribbon-desktop/files/shell/raster.tcl): a CRC32
# collision shows a miss, never another key's picture; the full key sits beside each disk
# entry and is compared on load (tests/raster-cache.tcl). Skips without wish8.6 or xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip raster cache (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if timeout 120 xvfb-run -a wish8.6 -encoding utf-8 tests/raster-cache.tcl "$T/work" </dev/null >"$T/out" 2>&1; then
	grep -c '  ok ' "$T/out" | sed 's/^/  ok   raster cache: /; s/$/ checks/'
	echo "raster cache: all checks passed"
	exit 0
fi
sed 's/^/       /' "$T/out"
echo "raster cache: checks failed"
exit 1
