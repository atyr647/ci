#!/bin/sh
# kit: a change's after-switch commands run before the store's garbage collection (tests/kit-txn-order.tcl).
# Needs Mk4tcl (KITFMT_MK4TCL) and minisign; skips without them or without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip kit's change order (no tclsh8.6)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if TMPDIR=$T timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/kit-txn-order.tcl >"$T/out" 2>&1; then
	if grep -q '^  skip' "$T/out"; then sed -n '/^  skip/p' "$T/out"; else echo "  ok   kit: the after-switch commands run before the store's gc ($(grep -c '^  ok ' "$T/out") checks)"; fi
else
	cat "$T/out"; echo "  FAIL kit's change order"; exit 1
fi
