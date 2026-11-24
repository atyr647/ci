#!/bin/sh
# The text editor (U26, U27, U28, U29, apps/editor): tests/editor-flow.tcl runs its procs under xvfb (the byte-for-byte
# round trip in four encodings, the dirty flag, Save as, the close sheet's answers, the open-documents list, tab
# overflow, the external-change check); tests/editor-highlight.tcl checks the syntax colours (golden tokens for each
# language, the syn_ tags of a file of each, the incremental retag); tests/editor-gutter.tcl checks the change bars
# (the line diff, the blocks, the bars against the file on disk, after a save and a scroll) and the folds; and
# tests/editor-find.tcl checks find and replace (the counts, the options, the keys as events, replace and undo as one
# step each, the options saved); tests/editor-split.tcl checks the split view (the keys, the 320 px minimum, the rule,
# the tabs across and at the edge, the caret of each pane); tests/editor-welcome.tcl checks the Welcome page (pins,
# reorder, the recent columns, the relative times, the menus, the fade); tests/editor-diagnostics.tcl checks nagelfar's
# findings (a stub on PATH: the parse, the debounce, the badges, the hover card, the waves, the status counts, and no
# nagelfar; only Tcl documents; the run in the background); tests/editor-window.tcl checks resizing under xvfb and, under
# a headless labwc of our own (when labwc and Xwayland are here), the strip's maximise button; tests/editor-scene.tcl
# draws each board's state and each is compared with its board (Editor-Final-1, -2, -3-Find-B's two windows,
# -4-Split-B, -5, -6-Welcome-B, -7 rendered by design/tools/render.js and cropped to the window at 100,74 (Find-B: its
# top 250 / 490 rows): the PNGs in tests/editor-fixtures/boards; both blurred, RMSE). What keeps each figure above zero:
# the boards' text that the scenes do not copy (the store.tcl caret column, the scroll's 10 px top pad, ui.tcl's dirty
# dot), the syntax colours of the build's rules where the boards colour fewer tokens, the rounded window corners the
# bare scene window lacks, and on -7 the breakpoint tag (not built: no debugger). Without wish8.6 or xvfb-run the step
# skips; without ImageMagick the comparison skips. Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip editor (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
APP=srcpkgs/ribbon-desktop/files/apps/editor/main.tcl
run() {
	# run NAME ENV... : xvfb with a scene or flow file; output in $T/NAME.out
	name=$1; shift
	HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" env "$@" \
		wish8.6 -encoding utf-8 "$APP" >"$T/$name.out" 2>&1
}
mkdir -p "$T/home" "$T/state" "$T/cache"
fails=0
if run flow RIBBON_EDITOR_SCENE="$PWD/tests/editor-flow.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-flow" \
	&& grep -q 'editor flow: all checks passed' "$T/flow.out"; then
	grep '  ok ' "$T/flow.out" | sed 's/^/  /'
	echo "editor flow: all checks passed"
else
	sed 's/^/       /' "$T/flow.out"; echo "editor flow: checks failed"; fails=$((fails + 1))
fi
if run highlight RIBBON_EDITOR_SCENE="$PWD/tests/editor-highlight.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-highlight" \
	&& grep -q 'editor highlight: all checks passed' "$T/highlight.out"; then
	grep '  ok ' "$T/highlight.out" | sed 's/^/  /'
	echo "editor highlight: all checks passed"
else
	sed 's/^/       /' "$T/highlight.out"; echo "editor highlight: checks failed"; fails=$((fails + 1))
fi
if run gutter RIBBON_EDITOR_SCENE="$PWD/tests/editor-gutter.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-gutter" \
	&& grep -q 'editor gutter: all checks passed' "$T/gutter.out"; then
	grep '  ok ' "$T/gutter.out" | sed 's/^/  /'
	echo "editor gutter: all checks passed"
else
	sed 's/^/       /' "$T/gutter.out"; echo "editor gutter: checks failed"; fails=$((fails + 1))
fi
if run find RIBBON_EDITOR_SCENE="$PWD/tests/editor-find.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-find" \
	&& grep -q 'editor find: all checks passed' "$T/find.out"; then
	grep '  ok ' "$T/find.out" | sed 's/^/  /'
	echo "editor find: all checks passed"
else
	sed 's/^/       /' "$T/find.out"; echo "editor find: checks failed"; fails=$((fails + 1))
fi
if run split RIBBON_EDITOR_SCENE="$PWD/tests/editor-split.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-split" \
	&& grep -q 'editor split: all checks passed' "$T/split.out"; then
	grep '  ok ' "$T/split.out" | sed 's/^/  /'
	echo "editor split: all checks passed"
else
	sed 's/^/       /' "$T/split.out"; echo "editor split: checks failed"; fails=$((fails + 1))
fi
if run welcome-checks RIBBON_EDITOR_SCENE="$PWD/tests/editor-welcome.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-welcome-checks" \
	&& grep -q 'editor welcome: all checks passed' "$T/welcome-checks.out"; then
	grep '  ok ' "$T/welcome-checks.out" | sed 's/^/  /'
	echo "editor welcome: all checks passed"
else
	sed 's/^/       /' "$T/welcome-checks.out"; echo "editor welcome: checks failed"; fails=$((fails + 1))
fi
if run diagnostics RIBBON_EDITOR_SCENE="$PWD/tests/editor-diagnostics.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-diagnostics" \
	RIBBON_EDITOR_SHOT="$T/diagnostics.png" \
	&& grep -q 'editor diagnostics: all checks passed' "$T/diagnostics.out"; then
	grep '  ok ' "$T/diagnostics.out" | sed 's/^/  /'
	echo "editor diagnostics: all checks passed"
else
	sed 's/^/       /' "$T/diagnostics.out"; echo "editor diagnostics: checks failed"; fails=$((fails + 1))
fi
if run window RIBBON_EDITOR_SCENE="$PWD/tests/editor-window.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-window" \
	&& grep -q 'editor window: all checks passed' "$T/window.out"; then
	grep '  ok ' "$T/window.out" | sed 's/^/  /'
	echo "editor window: all checks passed"
else
	sed 's/^/       /' "$T/window.out"; echo "editor window: checks failed"; fails=$((fails + 1))
fi
# the maximise button under a real compositor: our own headless labwc (its own runtime folder; only it is stopped)
if command -v labwc >/dev/null 2>&1 && command -v Xwayland >/dev/null 2>&1; then
	L="$T/labwc"; mkdir -p "$L/rt" "$L/cfg"; chmod 700 "$L/rt"
	printf 'echo "$DISPLAY" > "$XDG_RUNTIME_DIR/display"\n' >"$L/cfg/autostart"
	echo '<labwc_config><core><decoration>server</decoration></core></labwc_config>' >"$L/cfg/rc.xml"
	env -u WAYLAND_DISPLAY -u DISPLAY XDG_RUNTIME_DIR="$L/rt" WLR_BACKENDS=headless WLR_RENDERER=pixman \
		WLR_LIBINPUT_NO_DEVICES=1 timeout -k 5 90 labwc -C "$L/cfg" >"$L/log" 2>&1 &
	lpid=$!
	i=0; while [ ! -s "$L/rt/display" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	if [ -s "$L/rt/display" ] && HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
		env -u WAYLAND_DISPLAY DISPLAY="$(cat "$L/rt/display")" XDG_RUNTIME_DIR="$L/rt" RIBBON_EDITOR_WM=labwc \
		RIBBON_EDITOR_SCENE="$PWD/tests/editor-window.tcl" RIBBON_EDITOR_FIXTURES="$T/fx-wm" \
		timeout -k 5 60 wish8.6 -encoding utf-8 "$APP" >"$T/wm.out" 2>&1 \
		&& grep -q 'editor window: all checks passed' "$T/wm.out"; then
		grep '  ok ' "$T/wm.out" | sed 's/^/  /'
		echo "editor window (labwc): all checks passed"
	else
		cat "$T/wm.out" "$L/log" 2>/dev/null | tail -30 | sed 's/^/       /'; echo "editor window (labwc): checks failed"; fails=$((fails + 1))
	fi
	kill $lpid 2>/dev/null; wait $lpid 2>/dev/null
else
	echo "  skip the maximise button under labwc (no labwc / Xwayland)"
fi
for scene in normal many close list find replace split welcome diagnostics; do
	shot="$T/$scene.png"
	if run "$scene" RIBBON_EDITOR_SCENE="$PWD/tests/editor-scene.tcl" RIBBON_SCENE=$scene \
		RIBBON_EDITOR_FIXTURES="$T/fx-$scene" RIBBON_EDITOR_SHOT="$shot" \
		&& [ -s "$shot" ]; then
		echo "  ok   draws the $scene board state"
	else
		sed 's/^/       /' "$T/$scene.out"; echo "  FAIL draws the $scene board state"; fails=$((fails + 1)); continue
	fi
	board="tests/editor-fixtures/boards/$scene.png"
	[ -f "$board" ] || continue
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
		case $scene in
			normal) max=0.055 ;; many) max=0.057 ;; find) max=0.047 ;; replace) max=0.050 ;; split) max=0.065 ;;
			close) max=0.041 ;; welcome) max=0.042 ;; diagnostics) max=0.059 ;;
		esac
		geo=$(identify -format '%wx%h' "$board")
		convert "$shot" -crop "$geo+0+0" +repage -blur 0x2 "$T/$scene-a.png"
		convert "$board" -blur 0x2 "$T/$scene-b.png"
		r=$(compare -metric RMSE "$T/$scene-a.png" "$T/$scene-b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < $max) }"; then echo "  ok   the $scene state matches its board (blurred RMSE $r)"
		else echo "  FAIL the $scene state against its board: RMSE ${r:-?} (at most $max)"; fails=$((fails + 1)); fi
		# the strip's "+" and the window controls: muted on every board, at 50 % on the unfocused one (-7); the
		# brightest pixel of each, in the shot and on the board, within 12 levels
		if [ "$scene" = normal ] || [ "$scene" = diagnostics ]; then
			for zone in 40x30+470+10 90x30+1140+10; do
				a=$(convert "$shot" -crop "$zone" +repage -format '%[fx:int(maxima.r*255)]' info:)
				b=$(convert "$board" -crop "$zone" +repage -format '%[fx:int(maxima.r*255)]' info:)
				if [ $((a - b)) -le 12 ] && [ $((b - a)) -le 12 ]; then echo "  ok   the $scene strip at $zone is as bright as its board's ($a, $b)"
				else echo "  FAIL the $scene strip at $zone: brightest $a, the board's $b"; fails=$((fails + 1)); fi
			done
		fi
	else
		echo "  skip the $scene board comparison (no ImageMagick)"
	fi
done
[ $fails -eq 0 ] && echo "editor: all checks passed" || { echo "editor: $fails checks failed"; exit 1; }
