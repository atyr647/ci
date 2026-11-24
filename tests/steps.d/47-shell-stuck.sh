#!/bin/sh
# The shell's "not responding" notice (shell/mod-stuck.tcl) against a real client that stops reading its display
# socket: tests/shell-stuck.tcl. Skips without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip shell stuck (no tclsh8.6)"; exit 0; fi
timeout -k 5 90 tclsh8.6 tests/shell-stuck.tcl
