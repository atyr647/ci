#!/bin/sh
# Game HUD (U22): the readers against the fixture /proc and /sys trees (tests/hud-readers.tcl, tclsh), then the
# layouts, the no-frame state, the quick-menu shift and the drawing on a canvas (tests/hud-draw.tcl, wish under xvfb).
# Set HUD_SHOTS=dir to grab the scenes there. Skips the drawing without wish8.6 and xvfb-run.
set -u
cd "$(dirname "$0")/.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Game HUD (no tclsh8.6)"; exit 0; fi
st=0
if tclsh8.6 tests/hud-readers.tcl; then
	echo "  ok   Game HUD readers (tests/hud-readers.tcl)"
else
	echo "  FAIL Game HUD readers (tests/hud-readers.tcl)"; st=1
fi
if tclsh8.6 tests/hud-store.tcl >"${TMPDIR:-/tmp}/hud-store.$$.out" 2>&1; then
	echo "  ok   Game HUD settings store, game detection and frame pipes (tests/hud-store.tcl)"
else
	echo "  FAIL Game HUD settings store, game detection and frame pipes (tests/hud-store.tcl)"; grep -v '^  ok' "${TMPDIR:-/tmp}/hud-store.$$.out" | sed 's/^/       /'; st=1
fi
rm -f "${TMPDIR:-/tmp}/hud-store.$$.out"
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	if xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/hud-draw.tcl; then
		echo "  ok   Game HUD layouts, states and drawing (tests/hud-draw.tcl)"
	else
		echo "  FAIL Game HUD layouts and drawing (tests/hud-draw.tcl)"; st=1
	fi
else
	echo "  skip Game HUD drawing (no wish8.6 / xvfb-run)"
fi
exit $st
