#!/bin/sh
# Ribbon Files against its boards (design/mockups/Files-*.dc.html, design/tools/gen_files.py): the list view
# with kinds and item counts, the grid with thumbnails, the name-taken dialog and the archive menus, each drawn
# in the shell under xvfb (tests/files-scene.tcl) and compared with the board's crop (both blurred, RMSE < 0.05);
# then the flows behind them: Replace / Keep both / Skip and "Same for the other N", Extract here and Compress
# (bsdtar), and the freedesktop thumbnail cache. The crops are the PNGs in tests/files-fixtures/boards (each board
# rendered by design/tools/render.js at 1440 x 900 and cut to the geometry below), and the folder's pictures are
# tests/files-fixtures/photos, cut from Files-Grid-Thumbs. Without wish8.6, xvfb-run or ImageMagick the step skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
for c in wish8.6 xvfb-run convert compare; do
	command -v $c >/dev/null 2>&1 || { echo "  skip files scene (no $c)"; exit 0; }
done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
# unix_extra for the shell (built when missing, as tests/run.sh does)
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	if [ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ]; then
		mkdir -p "$T/ux"
		if make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1; then
			export TCLLIBPATH="$T/ux${TCLLIBPATH:+ $TCLLIBPATH}"
		fi
	fi
fi
run() { # scene, extra env (a UTF-8 locale, as the session has)
	sc=$1; shift
	mkdir -p "$T/$sc-home" "$T/$sc-run"
	env LC_ALL=C.UTF-8 HOME="$T/$sc-home" XDG_RUNTIME_DIR="$T/$sc-run" XDG_CACHE_HOME="$T/$sc-home/.cache" RIBBON_SCENE_FILES=0 \
		RIBBON_SHELL_TEST=tests/files-scene.tcl FILES_SCENE="$sc" "$@" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl \
		-name ribbon-shell >"$T/$sc.log" 2>&1
}
rmse() { # shot, board crop, geometry, label
	convert "$1" -crop "$3" +repage -blur 0x2 "$T/a.png"; convert "$2" -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $4 matches the board (blurred RMSE $r)"
	else echo "  FAIL $4 against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
}
B=tests/files-fixtures/boards
for sc in list thumbs conflict marchive mcompress flows; do
	if run "$sc" FILES_SHOT="$T/$sc.png" FILES_PHOTOS="$PWD/tests/files-fixtures/photos"; then
		grep -E '^  (ok|skip) ' "$T/$sc.log" | sed 's/^/  /'
		echo "  ok   files scene $sc drawn"
	else
		echo "  FAIL files scene $sc"; sed 's/^/       /' "$T/$sc.log"; fails=$((fails + 1)); continue
	fi
	[ "$sc" = flows ] && continue
	[ -s "$T/$sc.png" ] || { echo "  FAIL files scene $sc saved no picture"; fails=$((fails + 1)); continue; }
	case $sc in
		list) rmse "$T/$sc.png" "$B/list.png" 840x580+300+160 "the list view" ;;
		thumbs) rmse "$T/$sc.png" "$B/thumbs.png" 840x580+300+160 "the grid with thumbnails" ;;
		conflict) rmse "$T/$sc.png" "$B/conflict.png" 480x200+480+350 "the name-taken dialog" ;;
		marchive) rmse "$T/$sc.png" "$B/marchive.png" 240x327+670+556 "the archive's menu" ;;
		mcompress) rmse "$T/$sc.png" "$B/mcompress.png" 240x263+670+476 "the menu on five items" ;;
	esac
	[ -n "${FILES_SHOTS:-}" ] && mkdir -p "$FILES_SHOTS" && cp "$T/$sc.png" "$FILES_SHOTS/"
done
if [ "$fails" -eq 0 ]; then echo "files scene: all checks passed"; else echo "files scene: $fails failed"; exit 1; fi
