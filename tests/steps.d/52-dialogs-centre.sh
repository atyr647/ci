#!/bin/sh
# appearance/dialogs.tcl's message and question card is centred on its window's height (page::WH, else 720):
# tests/dialogs-centre.tcl runs dlg::draw under tclsh with the ui primitives stood in for. Without tclsh8.6 it skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip dialogs centre (no tclsh8.6)"; exit 0; fi
timeout -k 5 60 tclsh8.6 tests/dialogs-centre.tcl </dev/null
