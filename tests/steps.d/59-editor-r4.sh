#!/bin/sh
# The text editor's ⋯ menus and Go to line (boards Editor-R4-1-More, -2-Goto, -3-More-Split, -4-More-Welcome;
# design/tools/gen_editor_r4.py). tests/editor-r4.tcl runs under xvfb: the menus' rows and what each does, Go to line's
# keys as events (Ctrl+L in the window and in the text, digits only, Enter, past the end, Esc, Ctrl+F and Ctrl+L sharing
# the find bar's place, a split's focused pane). Then each board's state is drawn on top of tests/editor-scene.tcl's
# (normal, split, welcome) and compared with its board rendered by design/tools/render.js (the PNGs in
# tests/editor-fixtures/boards/r4-*.png; both blurred, RMSE): Go to line as the whole window (cropped at 100,74), each
# menu as its card with 10 px round it, taken where the build put it (the split scene's rule is not at the board's
# half: the menu follows its pane's ⋯). What keeps the figures above zero: the board's pointer on the hovered row, and
# on the window the scene's text where the board's differs (the editor's own scenes list these). Without wish8.6 or
# xvfb-run the step skips; without ImageMagick the comparison skips. Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip editor r4 (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
APP=srcpkgs/ribbon-desktop/files/apps/editor/main.tcl
run() {
	name=$1; shift
	mkdir -p "$T/$name/home" "$T/$name/state" "$T/$name/cache"
	HOME="$T/$name/home" XDG_STATE_HOME="$T/$name/state" XDG_CACHE_HOME="$T/$name/cache" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" env "$@" RIBBON_EDITOR_FIXTURES="$T/$name/fx" \
		wish8.6 -encoding utf-8 "$APP" >"$T/$name.out" 2>&1
}
fails=0
if run flow RIBBON_EDITOR_SCENE="$PWD/tests/editor-r4.tcl" RIBBON_R4=flow \
	&& grep -q 'editor r4: all checks passed' "$T/flow.out"; then
	grep '  ok ' "$T/flow.out" | sed 's/^/  /'
	echo "  ok   editor r4 flow: all checks passed"
else
	sed 's/^/       /' "$T/flow.out"; echo "  FAIL editor r4 flow"; fails=$((fails + 1))
fi
for scene in goto more moresplit morewelcome; do
	shot="$T/$scene.png"
	if run "$scene" RIBBON_EDITOR_SCENE="$PWD/tests/editor-r4.tcl" RIBBON_R4=$scene RIBBON_R4_SHOT="$shot" && [ -s "$shot" ]; then
		echo "  ok   draws the $scene board state"
	else
		sed 's/^/       /' "$T/$scene.out"; echo "  FAIL draws the $scene board state"; fails=$((fails + 1)); continue
	fi
	if ! command -v convert >/dev/null 2>&1 || ! command -v compare >/dev/null 2>&1; then
		echo "  skip the $scene board comparison (no ImageMagick)"; continue
	fi
	board="tests/editor-fixtures/boards/r4-$scene.png"
	if [ "$scene" = goto ]; then
		crop=1240x780+0+0
	else
		# the card where the build put it, 10 px round it, as large as the board's crop
		at=$(sed -n 's/^editor-r4: menu at \([0-9]*\) \([0-9]*\) size.*/\1 \2/p' "$T/$scene.out" | head -n1)
		case $at in [0-9]*' '[0-9]*) ;; *) echo "  FAIL the $scene menu was not open"; fails=$((fails + 1)); continue ;; esac
		crop="$(identify -format '%wx%h' "$board")+$((${at% *} - 10))+$((${at#* } - 10))"
	fi
	convert "$shot" -crop "$crop" +repage -blur 0x2 "$T/$scene-a.png"
	convert "$board" -blur 0x2 "$T/$scene-b.png"
	r=$(compare -metric RMSE "$T/$scene-a.png" "$T/$scene-b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   the $scene state matches its board (blurred RMSE $r)"
	else echo "  FAIL the $scene state against its board: RMSE ${r:-?} (at most 0.05)"; fails=$((fails + 1)); fi
	if [ "$scene" = goto ]; then
		# the row itself: the strip's foot to the row's rule (46 to 98), closer than the window
		convert "$shot" -crop 1240x52+0+46 +repage -blur 0x2 "$T/bar-a.png"
		convert "$board" -crop 1240x52+0+46 +repage -blur 0x2 "$T/bar-b.png"
		r=$(compare -metric RMSE "$T/bar-a.png" "$T/bar-b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.02) }"; then echo "  ok   the Go to line row matches its board (blurred RMSE $r)"
		else echo "  FAIL the Go to line row against its board: RMSE ${r:-?} (at most 0.02)"; fails=$((fails + 1)); fi
	fi
done
[ $fails -eq 0 ] && echo "editor r4: all checks passed" || { echo "editor r4: $fails checks failed"; exit 1; }
