#!/bin/sh
# Ribbon Files' copy and move (files::fileop_cmd in shell/files.tcl, run by sh): killed before each
# step and while cp runs, and the failures a user meets (tests/files-fileop.tcl). Plain tclsh, no display.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip files fileop (no tclsh8.6)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if timeout -k 5 600 tclsh8.6 tests/files-fileop.tcl >"$T/out" 2>&1; then
	grep '  ok ' "$T/out" | sed 's/^/  /'
	grep '  skip ' "$T/out" | sed 's/^/  /'
	echo "files fileop: all checks passed"
else
	sed 's/^/       /' "$T/out"
	echo "files fileop: checks failed"
	exit 1
fi
