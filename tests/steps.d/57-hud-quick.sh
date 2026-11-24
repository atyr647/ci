#!/bin/sh
# Game HUD quick menu (boards HUD-Quick-1-Menu, -2-Volume, -3-Quit): tests/hud-quick/run.sh. The model, the keys and the
# services against stand-ins (wpctl, ribbon-hdr, ribbon-screenshot, power-profiles-daemon on a private bus) and the
# geometry against the boards (tests/hud-quick.tcl, xvfb); then the real ribbon-hud-surface and daemon under a headless
# labwc (tests/hud-quick/native.sh): the scenes against the boards (blurred RMSE), Super+Esc over a fullscreen game
# (keyboard focus, the dim, the HUD beside the menu, the game gets no keys), the controller through evdev FIFOs, and
# Screenshot, Back to desktop and Quit game; Super+Esc and the home button on the desktop open nothing, the home button
# is left to Steam while a Steam client runs, a held arrow repeats at labwc's rate, a click through a virtual pointer
# takes a row and a click on the game closes the menu. Builds unix_extra when it is missing (power-profiles-daemon's
# stand-in).
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	if [ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ]; then
		mkdir -p "$T/ux"
		make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
		ux=$T/ux
	fi
fi
TCLLIBPATH="${ux:+$ux }${TCLLIBPATH:-}"; export TCLLIBPATH
if timeout -k 5 400 sh tests/hud-quick/run.sh; then
	echo "  ok   Game HUD quick menu (tests/hud-quick/run.sh)"
else
	echo "  FAIL Game HUD quick menu (tests/hud-quick/run.sh)"; exit 1
fi
