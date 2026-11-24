#!/bin/sh
# kit's prompt with more rows than the Properties window holds (Kit-Sheet-5-Long; srcpkgs/ribbon-desktop/files/
# properties/pages.tcl plan_sheet): the sheet stops 40 px short of the 720 px window's edges, its rows scroll by the
# wheel and the keys and the buttons stay put (scene longcheck); the drawn sheet against the board's crop
# (tests/properties-boards/sheet-long.png, from design/tools/gen_kitsys.py), both blurred, RMSE < 0.05.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v xvfb-run >/dev/null 2>&1 || ! command -v wish8.6 >/dev/null 2>&1; then echo "  skip long kit prompt (no xvfb-run / wish8.6)"; exit 0; fi
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
h=$T/home; tclsh8.6 -encoding utf-8 tests/properties-fixture.tcl "$h" graphite "$T/pics" >/dev/null
fails=0
scene() {
	sc=$1; shift
	env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_CACHE_HOME="$T/cache" \
		KIT_LIB=/nonexistent RIBBON_PROPERTIES_SCENE=tests/properties-scene.tcl RIBBON_SCENE=$sc "$@" \
		timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/properties/main.tcl"
}
out=$(scene longcheck 2>&1)
# 14 rows: 10 fit (720 - 80 - 88 - 72 = 480), the sheet is 640 tall; a wheel step moves one row, Down another (the rows focused), End to the last 10
if [ "$(printf '%s\n' "$out" | tr '\n' ' ')" = "sheet 640 fit 10 shown 10 wheel 1 down 2 end 4 button 625 " ]; then
	echo "  ok   a 14-row plan: a 640 px sheet showing 10 rows; the wheel, Down and End (the rows focused) scroll them, Return on them does nothing; the buttons stay at 625 (40 px above the window's foot, the footer's 17 px in)"
else
	echo "  FAIL the long plan's sheet and its scrolling:"; printf '%s\n' "$out" | sed 's/^/       /'; fails=$((fails + 1))
fi
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
	scene long RIBBON_PROPERTIES_SHOT="$T/shot.png" >"$T/out" 2>&1
	r=""
	if [ -s "$T/shot.png" ]; then
		convert "$T/shot.png" -crop 640x640+400+144 +repage -blur 0x2 "$T/a.png"; convert tests/properties-boards/sheet-long.png -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	fi
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   the long plan's sheet matches Kit-Sheet-5-Long (blurred RMSE $r)"
	else echo "  FAIL the long plan's sheet against Kit-Sheet-5-Long: RMSE ${r:-?}"; sed 's/^/       /' "$T/out"; fails=$((fails + 1)); fi
else
	echo "  skip the board comparison (no ImageMagick)"
fi
exit $((fails > 0))
