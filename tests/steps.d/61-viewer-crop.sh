#!/bin/sh
# The Image Viewer's crop and rotate, Info and wallpaper hand-off (apps/viewer/{crop,info,wall}.tcl):
# the steps and the files Save writes, read back as pixels with PIL, the EXIF kept with its
# orientation at 1, the wallpaper command on a stub (tests/viewer-crop.tcl, tests/viewer-crop-check.py);
# then under Tk, the crop driven as a user would (aspect, turns, flip, Straighten, a corner dragged,
# Save as copy) and the photo's EXIF read by Info (tests/viewer-crop-flow.tcl); then the Info edit
# view and the crop view drawn in the viewer's scene (tests/viewer-scene.tcl) and compared with Viewer-Final-2-Info,
# -3-Info-Edit, -8-Crop and -10-Crop-Copy (a WebP: Save as copy alone) (tests/viewer-fixtures/boards). The flow also clicks the photo toolbar's Rotate.
# Without tclsh8.6, PIL or ffmpeg the step skips; without wish8.6 or xvfb-run the Tk parts skip.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1 || ! python3 -c 'import PIL' >/dev/null 2>&1; then
	echo "  skip viewer crop (no tclsh8.6, ffmpeg or PIL)"
	exit 0
fi

if tclsh8.6 -encoding utf-8 tests/viewer-crop.tcl "$T/crop" >"$T/crop.out" 2>&1; then
	ok "crop: $(grep -c '  ok ' "$T/crop.out") checks (the steps, the saved pixels, the EXIF, the wallpaper command)"
else
	sed 's/^/       /' "$T/crop.out"; fail "viewer crop"
fi

if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Tk parts (no wish8.6 / xvfb-run)"
	[ $fails -eq 0 ] && echo "viewer crop: all checks passed" || echo "viewer crop: $fails checks failed"
	exit $((fails > 0))
fi

app=$PWD/srcpkgs/ribbon-desktop/files/apps/viewer/main.tcl
pic=$T/pic.png
tclsh8.6 tests/make-picture.tcl photo-dusk-0 1544 1029 "$pic" >/dev/null 2>&1
mkdir -p "$T/exif" && python3 tests/make-exif.py "$T/exif" >/dev/null 2>&1

if mkdir -p "$T/home-flow" && env HOME="$T/home-flow" XDG_CACHE_HOME="$T/cache" RIBBON_VIEWER_PIC="$pic" \
	RIBBON_VIEWER_EXIF="$T/exif" RIBBON_VIEWER_SCENE="$PWD/tests/viewer-crop-flow.tcl" \
	timeout 150 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$app" >"$T/flow.out" 2>&1 &&
	grep -q "^viewer crop flow: all checks passed" "$T/flow.out"; then
	ok "crop flow under Tk: $(grep -c '^ok ' "$T/flow.out") checks (aspect, turns, flip, Straighten, a corner, Save as copy; the camera from EXIF)"
else
	sed 's/^/       /' "$T/flow.out"; fail "viewer crop flow"
fi

# each state against its board: the board's own picture stands in for the photo (tests/viewer-fixtures/boards/
# picture.png, cut from Viewer-Final-1-Stage's render), the window is cut from the board's render at (100, 72) and
# both are blurred (RMSE < 0.035, as the monitor's scenes).
board=$PWD/tests/viewer-fixtures/boards
have_im=1
for c in convert compare; do command -v $c >/dev/null 2>&1 || have_im=0; done
for state in info edit crop cropcopy; do
	out=$T/$state.png
	if mkdir -p "$T/home-$state" && env HOME="$T/home-$state" XDG_CACHE_HOME="$T/cache" RIBBON_VIEWER_PIC="$board/picture.png" \
		RIBBON_VIEWER_STATE=$state RIBBON_VIEWER_SCENE="$PWD/tests/viewer-scene.tcl" RIBBON_VIEWER_SHOT="$out" \
		timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$app" >"$T/$state.log" 2>&1 && [ -s "$out" ]; then
		if grep -q "FAIL\|can't\|error" "$T/$state.log"; then fail "$state: a Tcl error"; sed 's/^/       /' "$T/$state.log"
		elif [ $have_im -eq 0 ]; then ok "$state drawn (no ImageMagick: not compared)"
		else
			convert "$out" +repage -blur 0x2 "$T/a.png"
			convert "$board/$state.png" -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < 0.035) }"; then ok "$state matches its board (blurred RMSE $r)"
			else fail "$state against its board: RMSE ${r:-?}"; fi
		fi
	else
		fail "$state did not draw"; sed 's/^/       /' "$T/$state.log"
	fi
done

[ $fails -eq 0 ] && echo "viewer crop: all checks passed" || echo "viewer crop: $fails checks failed"
exit $((fails > 0))
