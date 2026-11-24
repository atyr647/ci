#!/bin/sh
# Settings → Date and time, the page (page-datetime.tcl) under xvfb with datetime.tcl's readings and its helper call
# stood in for (tests/settings-datetime-scene.tcl): the page drawn in its two boards' states (Settings-A10-Date-Time;
# -A10b-Date-Picker, the picker open) and compared with the boards' crops in tests/fixtures/settings-pages (the page
# right of the rail; both blurred, RMSE), and every control pressed as a click or a key, checking what it asks the
# backend for; then the page with the real backend reading this machine's own zone and zone files (only the helper call
# stood in for): the real zone list opens, scrolls and jumps to typed text. The logic behind the page and the helper
# have their own steps (55-settings-datetime.sh, 56-settings-time-helper.sh). Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Date and time page (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the Date and time page (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon" "$T/run"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
fails=0
page() { # NAME RIBBON_SCENE
	name=$1
	if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run" TZ=UTC \
		RIBBON_SETTINGS_SCENE="$PWD/tests/settings-datetime-scene.tcl" RIBBON_DT_SHOT="$T/$name.png" RIBBON_DT_RESULT="$T/$name.res" RIBBON_SCENE="$2" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
		sed 's/^/  /' "$T/$name.res"
	else
		[ -f "$T/$name.res" ] && sed 's/^/  /' "$T/$name.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the $name page"; fails=$((fails + 1))
	fi
	# RIBBON_KEEP_SHOTS=DIR keeps the grabs, to look at them beside the boards
	if [ -n "${RIBBON_KEEP_SHOTS:-}" ] && [ -s "$T/$name.png" ]; then cp "$T/$name.png" "$RIBBON_KEEP_SHOTS/$name.png"; fi
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/$name.png" ]; then
		convert "$T/$name.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/settings-pages/$name.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $name matches the board (blurred RMSE $r)"; else echo "  FAIL $name against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	fi
}
page datetime main
page datetime-picker picker
# the real backend reading this machine (its zone, its zone files): the page draws and the real zone list works
if [ -f /usr/share/zoneinfo/Asia/Tokyo ]; then
	if env -u TZ -u RIBBON_TIME_TEST HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/run" \
		RIBBON_SETTINGS_SCENE="$PWD/tests/settings-datetime-real-scene.tcl" RIBBON_DT_RESULT="$T/real.res" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
		sed 's/^/  /' "$T/real.res"
	else
		[ -f "$T/real.res" ] && sed 's/^/  /' "$T/real.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the page on this machine's own zone files"; fails=$((fails + 1))
	fi
else
	echo "  skip the page on this machine's own zone files (no /usr/share/zoneinfo)"
fi
[ $fails -eq 0 ] && echo "Date and time page: all checks passed" || { echo "Date and time page: $fails failed"; exit 1; }
