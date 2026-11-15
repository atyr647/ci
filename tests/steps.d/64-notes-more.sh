#!/bin/sh
# Notes: the header's ⋯ menu built to boards Notes-R5-2-More and -3-More-Empty (design/tools/gen_notes_more.py).
# tests/notes-more.tcl runs under xvfb: the menu's place, size and rows on a note and on the empty folder; it closes
# on a press outside, Escape or the ⋯ again; New note, New folder, Import… (Ribbon's chooser stood in for) and Move
# to Trash (the file under .trash, the next note opened, Trash lists it, Restore, the last note leaving the empty
# folder) do their jobs. Then tests/notes-scene.tcl's tree and empty states with the menu open are compared with the
# boards rendered by design/tools/render.js and cropped to the window at 100,74 (tests/notes-fixtures/boards/
# more.png, more-empty.png; both blurred, RMSE < 0.05); what keeps them above zero is the scenes' own and the
# boards' pointer. Without wish8.6 or xvfb-run the step skips; without ImageMagick the comparison skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip notes more (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
APP=srcpkgs/ribbon-desktop/files/apps/notes/main.tcl
status=0
for m in flow note empty; do
	mkdir -p "$T/$m/home" "$T/$m/state" "$T/$m/cache"
	HOME="$T/$m/home" XDG_STATE_HOME="$T/$m/state" XDG_CACHE_HOME="$T/$m/cache" RIBBON_MORE=$m \
		RIBBON_NOTES_SCENE="$PWD/tests/notes-more.tcl" RIBBON_NOTES_FIXTURES="$T/$m/fx" RIBBON_NOTES_SHOT="$T/$m.png" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$APP" </dev/null >"$T/$m.out" 2>&1
done
if grep -q 'notes more: all checks passed' "$T/flow.out"; then
	grep '  ok ' "$T/flow.out" | sed 's/^/  /'; echo "  ok   notes more flow: all checks passed"
else
	sed 's/^/       /' "$T/flow.out"; echo "  FAIL notes more flow"; status=1
fi
for m in note empty; do
	b=$([ $m = note ] && echo more || echo more-empty)
	if [ -s "$T/$m.png" ]; then
		if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
			convert "$T/$m.png" -blur 0x2 "$T/a.png"
			convert "tests/notes-fixtures/boards/$b.png" -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   the ⋯ menu ($m) matches its board (blurred RMSE $r)"
			else echo "  FAIL the ⋯ menu ($m) against its board: RMSE ${r:-?} (at most 0.05)"; status=1; fi
		else
			echo "  skip the ⋯ menu board comparison (no ImageMagick)"
		fi
	else
		sed 's/^/       /' "$T/$m.out"; echo "  FAIL draws the ⋯ menu's board state ($m)"; status=1
	fi
done
[ $status -eq 0 ] && echo "notes more: all checks passed" || echo "notes more: checks failed"
exit $status
