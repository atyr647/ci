#!/bin/sh
# Notes (U33 model, U34 UI): tests/notes-store.tcl runs the store, Markdown, index and search with tclsh; then
# the boards' states (tree, edit, empty, search, capture) are drawn headless under xvfb with tests/notes-scene.tcl
# and each is compared with its board (Notes-R4-A-Tree, -A2-Edit, -A3-Empty, -A4-Search, -A5-Capture rendered by
# design/tools/render.js and cropped to the 1240 x 780 window at 100,74, or the capture panel at 460,132: the PNGs in
# tests/notes-fixtures/boards; both blurred, RMSE). What keeps each figure above zero: the photo fixtures, the dates
# and "Edited" times of the day the test runs, the code block's square corners (a text widget) and, on the edit
# board, the code colours of the Text editor's rules where the board colours only keywords and variables.
# tests/notes-page.tcl checks the note page's W1 fixes (style menu, links, code colours, done items, rename by title,
# resizing). Without tclsh8.6, wish8.6 or xvfb-run the scene checks skip; without ImageMagick the comparison skips.
# Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
status=0
if command -v tclsh8.6 >/dev/null 2>&1; then
	if timeout -k 5 60 tclsh8.6 tests/notes-store.tcl </dev/null; then :; else echo "  FAIL notes store"; status=1; fi
else
	echo "  skip notes store (no tclsh8.6)"
fi
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	T=$(mktemp -d)
	for sc in tree edit empty search capture; do
		mkdir -p "$T/$sc/home" "$T/$sc/state" "$T/$sc/cache"
		if HOME="$T/$sc/home" XDG_STATE_HOME="$T/$sc/state" XDG_CACHE_HOME="$T/$sc/cache" \
			RIBBON_NOTES_SCENE="$PWD/tests/notes-scene.tcl" RIBBON_SCENE=$sc RIBBON_NOTES_FIXTURES="$T/$sc/fx" \
			RIBBON_NOTES_SHOT="$T/$sc/shot.png" timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" \
			wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/notes/main.tcl >"$T/$sc/out" 2>&1 && [ -s "$T/$sc/shot.png" ]
		then echo "  ok   draws the $sc board state"
		else sed 's/^/       /' "$T/$sc/out"; echo "  FAIL draws the $sc board state"; status=1; continue; fi
		if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
			case $sc in tree) max=0.052 ;; edit) max=0.038 ;; empty) max=0.016 ;; search) max=0.046 ;; capture) max=0.031 ;; esac
			convert "$T/$sc/shot.png" -blur 0x2 "$T/$sc/a.png"
			convert "tests/notes-fixtures/boards/$sc.png" -blur 0x2 "$T/$sc/b.png"
			r=$(compare -metric RMSE "$T/$sc/a.png" "$T/$sc/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < $max) }"; then echo "  ok   the $sc state matches its board (blurred RMSE $r)"
			else echo "  FAIL the $sc state against its board: RMSE ${r:-?} (at most $max)"; status=1; fi
		else
			echo "  skip the $sc board comparison (no ImageMagick)"
		fi
	done
else
	echo "  skip notes scenes (no wish8.6 / xvfb-run)"
fi
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	T=$(mktemp -d)
	mkdir -p "$T/home" "$T/state" "$T/cache"
	if HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache" \
		RIBBON_NOTES_SCENE="$PWD/tests/notes-flow.tcl" RIBBON_NOTES_FIXTURES="$T/fx" timeout -k 5 120 \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/notes/main.tcl \
		>"$T/flow.out" 2>&1 && grep -q "^flow: ok" "$T/flow.out"
	then echo "  ok   the note page flow (round trip, checkbox, Bold, find, undo)"
	else sed 's/^/       /' "$T/flow.out"; echo "  FAIL the note page flow"; status=1; fi
	# the note page's W1 fixes: the Text style menu, links (a stub xdg-open), code colours, done items, rename by title,
	# resizing
	mkdir -p "$T/pg/home" "$T/pg/state" "$T/pg/cache"
	if HOME="$T/pg/home" XDG_STATE_HOME="$T/pg/state" XDG_CACHE_HOME="$T/pg/cache" \
		RIBBON_NOTES_SCENE="$PWD/tests/notes-page.tcl" RIBBON_NOTES_FIXTURES="$T/pg/fx" timeout -k 5 120 \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/notes/main.tcl \
		</dev/null >"$T/pg.out" 2>&1 && grep -q "^page: ok" "$T/pg.out"
	then echo "  ok   the note page (style menu, links, code colours, done items, rename by title, resize)"
	else sed 's/^/       /' "$T/pg.out"; echo "  FAIL the note page"; status=1; fi
	# the quick capture: Save to Inbox, Discard, and the --capture hand-off to the running app's socket
	mkdir -p "$T/cap/home" "$T/cap/state" "$T/cap/cache"
	if HOME="$T/cap/home" XDG_STATE_HOME="$T/cap/state" XDG_CACHE_HOME="$T/cap/cache" XDG_RUNTIME_DIR="$T/cap/run" \
		RIBBON_NOTES_SCENE="$PWD/tests/notes-capture.tcl" RIBBON_NOTES_FIXTURES="$T/cap/fx" timeout -k 5 120 \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/apps/notes/main.tcl \
		</dev/null >"$T/cap.out" 2>&1 && grep -q "^capture: ok" "$T/cap.out"
	then echo "  ok   the quick capture (Save to Inbox, Discard, hand-off from --capture)"
	else sed 's/^/       /' "$T/cap.out"; echo "  FAIL the quick capture"; status=1; fi
fi
exit $status
