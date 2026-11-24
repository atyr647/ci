#!/bin/sh
# The login screen's account picture loader refuses a picture whose header declares more than 2048 pixels a side or 4 million
# pixels (tests/greeter-face.tcl): a decompression bomb at ~/.face could freeze or kill the greeter every user logs in through.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip the greeter's picture limits (no tclsh8.6)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 60 tclsh8.6 -encoding utf-8 tests/greeter-face.tcl >"$T/out" 2>&1; then
	echo "  ok   the greeter refuses pictures that declare more than 2048 px a side or 4 MP, from the header ($(grep -c '^  ok ' "$T/out") checks)"
else
	cat "$T/out"; echo "  FAIL the greeter's picture limits"; exit 1
fi
