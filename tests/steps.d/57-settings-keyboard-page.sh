#!/bin/sh
# Settings → Keyboard and mouse, the page (page-keyboard.tcl) under xvfb with input.tcl stood in for
# (tests/settings-keyboard-scene.tcl): drawn in its board's state and compared with the board's crop in
# tests/fixtures/settings-pages/keyboard.png (the page right of the rail; both blurred, RMSE < 0.05), then every
# control pressed as a click (the dropdowns' lists, the segmented control, the sliders' ends, the switches) and the
# backend call each makes checked; a refused change; the page with no touchpad. The logic behind the page has its
# own steps (55-settings-input.sh, 65-settings-input-live.sh). Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Keyboard and mouse page (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the Keyboard and mouse page (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
fails=0
page() { # NAME SCENE-FILE SHOT-VAR RESULT-VAR [RIBBON_SCENE]
	name=$1
	if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SETTINGS_SCENE="$PWD/$2" "$3=$T/$name.png" "$4=$T/$name.res" RIBBON_SCENE="${5:-main}" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
		sed 's/^/  /' "$T/$name.res"
	else
		[ -f "$T/$name.res" ] && sed 's/^/  /' "$T/$name.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the $name page"; fails=$((fails + 1))
	fi
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/$name.png" ]; then
		convert "$T/$name.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/settings-pages/$name.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $name matches the board (blurred RMSE $r)"; else echo "  FAIL $name against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	fi
}
page keyboard tests/settings-keyboard-scene.tcl RIBBON_KBD_SHOT RIBBON_KBD_RESULT
[ -n "${SHOTS:-}" ] && cp "$T"/keyboard*.png "$SHOTS"/ 2>/dev/null
[ $fails -eq 0 ] && echo "Keyboard and mouse page: all checks passed" || { echo "Keyboard and mouse page: $fails failed"; exit 1; }
