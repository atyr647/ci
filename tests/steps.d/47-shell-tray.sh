#!/bin/sh
# Apps' tray icons and the bar's tooltips (shell/sniwatch.tcl, tray.tcl, tooltip.tcl, mod-tray.tcl; boards Tray-1-Icons,
# Tray-2-Menu, Tray-3-Submenu, Tray-4-Fallback, Tooltip-1-Bar): tests/shell-tray.tcl in the real shell under xvfb on a private session bus, with Steam
# and Discord stood in for through GLib's D-Bus (tests/fixtures/sni-items.py, python3 with gi), then its grabs of the
# right bar against the boards' crops in tests/fixtures/tray (both blurred, RMSE < 0.05).
# Skips without wish8.6, xvfb-run, dbus-daemon, gdbus, ImageMagick or a python3 with gi.
# NOT covered: the real Steam and Discord, a watcher another desktop serves, HiDPI.
set -u
cd "$(dirname "$0")/../.." || exit 1
for c in wish8.6 xvfb-run dbus-daemon gdbus import convert compare; do
	command -v "$c" >/dev/null 2>&1 || { echo "  skip the tray (no $c)"; exit 0; }
done
PY=
for py in python3 /usr/bin/python3 /usr/bin/python3.12; do
	if "$py" -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' >/dev/null 2>&1; then PY=$py; break; fi
done
[ -n "$PY" ] || { echo "  skip the tray (no python3 with gi)"; exit 0; }
repo=$(pwd)
D=$repo/srcpkgs/ribbon-desktop/files
T=$(mktemp -d)
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$T/h" "$T/c" "$T/s" "$T/r" "$T/cfg/ribbon" "$T/shots" "$T/t"
chmod 700 "$T/r"
cp "$D/themes/palettes/ribbon.conf" "$T/cfg/ribbon/palette.conf"
# no battery percentage beside the glyph (the boards draw none)
echo BAR_PERCENT=no >"$T/cfg/ribbon/power.conf"
# PNGs as other programs write them: filtered rows, and a palette with transparency
convert -size 32x32 xc:none -fill white -draw 'circle 16,16 16,4' -fill '#336699' -draw 'rectangle 4,4 10,12' "$T/t/filtered.png"
convert -size 32x32 xc:none -fill '#FF7A59' -draw 'circle 16,16 16,6' PNG8:"$T/t/palette.png"

# the private session bus
timeout 150 dbus-daemon --nofork --nopidfile --session --print-address=3 3>"$T/bus.addr" 2>"$T/daemon.log" &
pids="$pids $!"
i=0
while [ ! -s "$T/bus.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/bus.addr" ] || { cat "$T/daemon.log"; echo "  FAIL the tray: dbus-daemon did not start"; exit 1; }
DBUS_SESSION_BUS_ADDRESS=$(head -n 1 "$T/bus.addr")
export DBUS_SESSION_BUS_ADDRESS
# the shell's ribbon::dbus needs unix_extra: built here when tclsh lacks it
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the tray (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"
export TCLLIBPATH

fails=0
if HOME=$T/h XDG_CACHE_HOME=$T/c XDG_STATE_HOME=$T/s XDG_RUNTIME_DIR=$T/r XDG_CONFIG_HOME=$T/cfg \
	TRAY_TMP=$T/t TRAY_SHOTS=$T/shots TRAY_PYTHON=$PY TRAY_FIXTURES=$repo/tests/fixtures RIBBON_SHELL_TEST=tests/shell-tray.tcl \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$T/out" 2>&1 &&
	grep -q '^tray: all checks passed$' "$T/out" && ! grep -q '  FAIL' "$T/out"; then
	sed -n 's/^  ok   /  ok   tray: /p' "$T/out"
else
	sed 's/^/       /' "$T/out"; echo "  FAIL the tray in the shell (tests/shell-tray.tcl)"; fails=$((fails + 1))
fi
# the grabs and the fixtures are the boards' 520 px at the screen's top right (x 920); compared are the insides of
# what the shell draws (under xvfb there is no wallpaper and no compositor behind the bar): the bar's row, the pill,
# the menu's rows
# (the lit slot is grabbed before the pill comes: without a compositor the pill's window, shadow and all, hides the bar)
for s in "Tray-1-Icons:Tray-1-Icons:468x30+40+12:the right bar" "Tooltip-1-Bar-slot:Tooltip-1-Bar:468x30+40+12:the lit slot" \
	"Tooltip-1-Bar:Tooltip-1-Bar:52x20+118+55:the tooltip" "Tray-2-Menu:Tray-2-Menu:468x30+40+12:the bar over the menu" \
	"Tray-2-Menu:Tray-2-Menu:464x350+40+58:the menu" "Tray-3-Submenu:Tray-3-Submenu:464x440+40+58:the menu with a submenu and checks" \
	"Tray-4-Fallback:Tray-4-Fallback:468x30+40+12:the right bar with an unreadable icon"; do
	shot=${s%%:*}; rest=${s#*:}; b=${rest%%:*}; rest=${rest#*:}; crop=${rest%%:*}; what=${rest#*:}
	[ -s "$T/shots/$shot.png" ] || { echo "  FAIL no grab for $shot"; fails=$((fails + 1)); continue; }
	convert "$T/shots/$shot.png" -crop "$crop" +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/tray/$b.png" -crop "$crop" +repage -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $what matches $b (blurred RMSE $r)"
	else echo "  FAIL $what against $b: RMSE ${r:-?}"; fails=$((fails + 1)); fi
done
[ $fails -eq 0 ] || exit 1
