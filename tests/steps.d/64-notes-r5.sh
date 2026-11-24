#!/bin/sh
# Notes: the Text style menu built to board Notes-R5-1-Style (design/tools/gen_editor_r4.py), Import, the tree's tag
# chips and the canvas' presses. tests/notes-r5.tcl runs under xvfb: the menu's place, size, rows, check, hover and
# choices; Import through the empty folder's button with Ribbon's chooser stood in for (front matter, pictures copied
# and relinked, taken names numbered, nothing replaced); a TAGS chip's click filters the tree and a second clears it;
# the bar's New note as a real press. Then tests/notes-scene.tcl's edit state with the menu open is compared with the
# board rendered by design/tools/render.js and cropped to the window at 100,74 (tests/notes-fixtures/boards/r5-style.png;
# both blurred, RMSE); what keeps it above zero is the edit scene's own (dates, the photo, the code colours) and the
# board's pointer. Without wish8.6 or xvfb-run the step skips; without ImageMagick the comparison skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip notes r5 (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
APP=srcpkgs/ribbon-desktop/files/apps/notes/main.tcl
status=0
for m in flow style; do
	mkdir -p "$T/$m/home" "$T/$m/state" "$T/$m/cache"
	HOME="$T/$m/home" XDG_STATE_HOME="$T/$m/state" XDG_CACHE_HOME="$T/$m/cache" RIBBON_R5=$m \
		RIBBON_NOTES_SCENE="$PWD/tests/notes-r5.tcl" RIBBON_NOTES_FIXTURES="$T/$m/fx" RIBBON_NOTES_SHOT="$T/style.png" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$APP" </dev/null >"$T/$m.out" 2>&1
done
if grep -q 'notes r5: all checks passed' "$T/flow.out"; then
	grep '  ok ' "$T/flow.out" | sed 's/^/  /'; echo "  ok   notes r5 flow: all checks passed"
else
	sed 's/^/       /' "$T/flow.out"; echo "  FAIL notes r5 flow"; status=1
fi
if [ -s "$T/style.png" ]; then
	echo "  ok   draws the Text style menu's board state"
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
		convert "$T/style.png" -blur 0x2 "$T/a.png"
		convert tests/notes-fixtures/boards/r5-style.png -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   the style menu state matches its board (blurred RMSE $r)"
		else echo "  FAIL the style menu state against its board: RMSE ${r:-?} (at most 0.05)"; status=1; fi
	else
		echo "  skip the style menu board comparison (no ImageMagick)"
	fi
else
	sed 's/^/       /' "$T/style.out"; echo "  FAIL draws the Text style menu's board state"; status=1
fi
[ $status -eq 0 ] && echo "notes r5: all checks passed" || echo "notes r5: checks failed"
exit $status
