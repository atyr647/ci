#!/bin/sh
# The bar's updates panel on kit's fixture store (tests/shell-updates.tcl): kit's plan and question, Cancel,
# the grab through kit, Done, History and Rewind, in the real shell under xvfb (hard 300 s limit; the shell
# inside has its own 140 s one). It needs minisign, Mk4tcl (KITFMT_MK4TCL=<dir>), xvfb-run and wish8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if command -v minisign >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1 &&
	echo 'exit [catch {package require Mk4tcl}]' | TCLLIBPATH="${KITFMT_MK4TCL:-}" tclsh8.6 >/dev/null 2>&1; then
	if timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/shell-updates.tcl; then
		echo "  ok   the bar's updates panel"
	else
		echo "  FAIL the bar's updates panel (tests/shell-updates.tcl)"; exit 1
	fi
else
	echo "  skip the bar's updates panel (needs minisign, Mk4tcl, xvfb-run and wish8.6)"
fi
