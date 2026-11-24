#!/bin/sh
# Ribbon Terminal's kept state (shell/mod-term.tcl): tests/term-state.tcl, pure Tcl. The real fault.tcl and mod-term.tcl
# run in child interpreters, one per shell, with the window manager, Tk and labwc stubbed: save, a simulated restart,
# restore, then snap restore gives the rectangle from before the snap. Needs tclsh8.6 only.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip term state (no tclsh8.6)"; exit 0; }
timeout 120 tclsh8.6 tests/term-state.tcl
