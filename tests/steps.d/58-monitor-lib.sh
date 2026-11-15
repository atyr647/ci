#!/bin/sh
# System monitor libraries (U24): apps/monitor/{proc,group,gpu,services,history}.tcl on the fixture
# trees in tests/monitor-fixtures (readers, rates, grouping, GPU fdinfo, rings, and real signals to
# sacrificial processes). Pure Tcl: skips only when tclsh is missing.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh >/dev/null 2>&1; then
	echo "  skip monitor libraries (no tclsh)"
	exit 0
fi
if timeout -k 5 120 tclsh -encoding utf-8 tests/monitor-lib.tcl; then
	echo "monitor libraries: all checks passed"
else
	echo "monitor libraries: checks failed"; exit 1
fi
