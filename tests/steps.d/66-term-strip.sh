#!/bin/sh
# Terminal tab strip, Pills A (apps/term/strip.tcl): tests/term-strip.tcl draws the four-tab and thirteen-tab boards'
# strips at 1240 px under xvfb, checks the pills, the fold, the activity dot and each click's callback, and compares
# both strips with the board crops in tests/fixtures/term-strip. Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the terminal tab strip (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if timeout -k 5 90 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/term-strip.tcl >"$T/out" 2>&1 \
	&& grep -q 'term-strip: all checks passed' "$T/out"; then
	grep '  ok ' "$T/out" | sed 's/^/  /'
	echo "terminal tab strip: all checks passed"
else
	sed 's/^/       /' "$T/out"; echo "terminal tab strip: checks failed"; exit 1
fi
