#!/bin/sh
# Ribbon's alert (shell/alert.tcl): tests/alert-scene.tcl draws boards Alert-1-Video-Long, Alert-1b-Not-Applied and
# Alert-2-Term-Close-Tab under xvfb and compares them with the board crops in tests/fixtures/alert, checks the
# buttons' places, and answers real alerts by click, Return, Esc and alert::ask. Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the alert (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if TMPDIR=$T timeout -k 5 90 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/alert-scene.tcl >"$T/out" 2>&1 \
	&& grep -q 'alert: all checks passed' "$T/out"; then
	grep '  ok \|  skip ' "$T/out" | sed 's/^/  /'
	echo "alert: all checks passed"
else
	sed 's/^/       /' "$T/out"; echo "alert: checks failed"; exit 1
fi
